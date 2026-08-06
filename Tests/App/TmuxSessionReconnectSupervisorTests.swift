import Foundation
import Testing
@testable import GhosthubApp

@MainActor
private final class ReconnectAttemptCounter {
    private(set) var count = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var cancellations = 0

    @discardableResult
    func begin() -> Int {
        count += 1
        active += 1
        maximumActive = max(maximumActive, active)
        return count
    }

    func end(cancelled: Bool = false) {
        active -= 1
        if cancelled {
            cancellations += 1
        }
    }
}

private actor ReconnectAttemptGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = false

    func wait() async {
        blocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func isBlocked() -> Bool {
        blocked
    }

    func open() {
        blocked = false
        continuation?.resume()
        continuation = nil
    }
}

private actor ReconnectSleepRecorder {
    private(set) var count = 0

    func sleep(_ duration: Duration) async throws {
        count += 1
        try await Task.sleep(for: duration)
    }
}

@Suite("Tmux reconnect supervisor", .serialized)
@MainActor
struct TmuxSessionReconnectSupervisorTests {
    @Test(
        "probe runtime counts against the attempt-start interval",
        arguments: [
            (
                Duration.seconds(1),
                Duration.milliseconds(250),
                Duration.milliseconds(750)
            ),
            (Duration.seconds(2), Duration.seconds(3), Duration.zero),
            (Duration.seconds(30), Duration.seconds(15), Duration.seconds(15)),
        ]
    )
    func remainingDelay(
        interval: Duration,
        elapsed: Duration,
        expected: Duration
    ) {
        #expect(TmuxSessionReconnectSupervisor.remainingDelay(
            interval: interval,
            elapsed: elapsed
        ) == expected)
    }

    @Test("failed attempts continue until one stops the supervisor")
    func retriesUntilStopped() async {
        let attempts = ReconnectAttemptCounter()
        let supervisor = TmuxSessionReconnectSupervisor(
            intervals: [.milliseconds(1)],
            probeDeadline: .seconds(1)
        )
        supervisor.start {
            let count = attempts.begin()
            attempts.end()
            return count == 3 ? .stop : .retry
        }

        await waitUntilMainActor {
            attempts.count == 3 && !supervisor.isRunning
        }

        #expect(!supervisor.isRunning)
    }

    @Test("Reconnect Now interrupts the pending delay")
    func reconnectNowInterruptsDelay() async {
        let attempts = ReconnectAttemptCounter()
        let sleeps = ReconnectSleepRecorder()
        let supervisor = TmuxSessionReconnectSupervisor(
            intervals: [.seconds(10)],
            probeDeadline: .seconds(1),
            sleep: { try await sleeps.sleep($0) }
        )
        supervisor.start {
            let count = attempts.begin()
            attempts.end()
            return count == 2 ? .stop : .retry
        }
        await waitUntil { await sleeps.count == 1 }

        supervisor.reconnectNow()
        await waitUntilMainActor(timeout: .milliseconds(250)) {
            attempts.count == 2 && !supervisor.isRunning
        }

        #expect(!supervisor.isRunning)
    }

    @Test("Reconnect Now never overlaps an in-flight attempt")
    func reconnectNowDoesNotOverlapProbe() async {
        let attempts = ReconnectAttemptCounter()
        let gate = ReconnectAttemptGate()
        let supervisor = TmuxSessionReconnectSupervisor(
            intervals: [.milliseconds(1)],
            probeDeadline: .seconds(1)
        )
        supervisor.start {
            let count = attempts.begin()
            if count == 1 {
                await gate.wait()
            }
            attempts.end()
            return count == 2 ? .stop : .retry
        }
        await waitUntil { await gate.isBlocked() }

        supervisor.reconnectNow()
        try? await Task.sleep(for: .milliseconds(25))
        #expect(attempts.count == 1)
        #expect(attempts.maximumActive == 1)

        await gate.open()
        await waitUntilMainActor { attempts.count == 2 }
        #expect(attempts.maximumActive == 1)
    }

    @Test("cancel ignores a stale attempt completion")
    func cancelIgnoresStaleCompletion() async {
        let attempts = ReconnectAttemptCounter()
        let gate = ReconnectAttemptGate()
        let supervisor = TmuxSessionReconnectSupervisor(
            intervals: [.milliseconds(1)],
            probeDeadline: .seconds(1)
        )
        supervisor.start {
            attempts.begin()
            await gate.wait()
            attempts.end()
            return .retry
        }
        await waitUntil { await gate.isBlocked() }

        supervisor.cancel()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(25))

        #expect(attempts.count == 1)
        #expect(!supervisor.isRunning)
    }

    @Test("overlong probes are cancelled before retrying")
    func cancelsOverlongProbe() async {
        let attempts = ReconnectAttemptCounter()
        let supervisor = TmuxSessionReconnectSupervisor(
            intervals: [.milliseconds(1)],
            probeDeadline: .milliseconds(20)
        )
        supervisor.start {
            let count = attempts.begin()
            guard count == 1 else {
                attempts.end()
                return .stop
            }
            do {
                try await Task.sleep(for: .seconds(10))
                attempts.end()
            } catch {
                attempts.end(cancelled: true)
            }
            return .retry
        }

        await waitUntilMainActor {
            attempts.count == 2 && !supervisor.isRunning
        }

        #expect(attempts.cancellations == 1)
        #expect(attempts.maximumActive == 1)
        #expect(!supervisor.isRunning)
    }
}
