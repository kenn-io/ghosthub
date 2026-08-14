import Foundation
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private final class HerdrProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}

private final class HerdrProbeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var active = 0
    private var maximumActive = 0
    private var cancellations = 0

    func begin() -> Int {
        lock.withLock {
            starts += 1
            active += 1
            maximumActive = max(maximumActive, active)
            return starts
        }
    }

    func end(cancelled: Bool = false) {
        lock.withLock {
            active -= 1
            if cancelled {
                cancellations += 1
            }
        }
    }

    var snapshot: (
        starts: Int,
        maximumActive: Int,
        cancellations: Int
    ) {
        lock.withLock { (starts, maximumActive, cancellations) }
    }
}

private actor HerdrProbeGate {
    private var waiters = [CheckedContinuation<Void, Never>]()
    private var arrivalWaiters = [CheckedContinuation<Void, Never>]()
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            let arrivals = arrivalWaiters
            arrivalWaiters.removeAll()
            arrivals.forEach { $0.resume() }
        }
    }

    func waitUntilBlocked(count: Int = 1) async {
        guard waiters.count < count else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
        if waiters.count < count {
            await waitUntilBlocked(count: count)
        }
    }

    func open() {
        isOpen = true
        let blocked = waiters
        waiters.removeAll()
        blocked.forEach { $0.resume() }
    }
}

@Suite("Herdr session probe broker")
struct HerdrSessionProbeBrokerTests {
    @MainActor
    @Test("concurrent consumers share one discovery and receive its result")
    func concurrentConsumers() async {
        let calls = HerdrProbeCounter()
        let gate = HerdrProbeGate()
        let expected = HerdrDiscoveryResult.available([
            HerdrSessionSummary(
                name: "api",
                isDefault: true,
                state: .running
            ),
        ])
        let broker = HerdrSessionProbeBroker { _ in
            calls.increment()
            await gate.wait()
            return expected
        }

        async let first = broker.sessions(on: .local)
        async let second = broker.sessions(on: .local)
        await gate.waitUntilBlocked()
        await Task.yield()
        await gate.open()

        #expect(await first == expected)
        #expect(await second == expected)
        #expect(calls.count == 1)
    }

    @MainActor
    @Test("completed discoveries are never cached")
    func sequentialCallsAreFresh() async {
        let calls = HerdrProbeCounter()
        let broker = HerdrSessionProbeBroker { _ in
            calls.increment()
            return .available([])
        }

        _ = await broker.sessions(on: .local)
        _ = await broker.sessions(on: .local)

        #expect(calls.count == 2)
    }

    @MainActor
    @Test("invalidation cancels consumers and drains before replacement")
    func invalidationDrains() async {
        let lifetime = HerdrProbeLifetime()
        let drain = HerdrProbeGate()
        let broker = drainingBroker(lifetime: lifetime, drain: drain)

        let first = Task { await broker.sessions(on: .local) }
        await waitUntilMainActor { lifetime.snapshot.starts == 1 }
        broker.invalidateSessions(on: .local)
        #expect(await first.value == .failure(.cancelled(host: "localhost")))

        let replacement = Task { await broker.sessions(on: .local) }
        try? await Task.sleep(for: .milliseconds(25))
        #expect(lifetime.snapshot.starts == 1)
        #expect(lifetime.snapshot.maximumActive == 1)

        await drain.open()
        #expect(await replacement.value == .available([]))
        #expect(lifetime.snapshot.starts == 2)
        #expect(lifetime.snapshot.maximumActive == 1)
        #expect(lifetime.snapshot.cancellations == 1)
    }

    @MainActor
    @Test("cancelling the sole consumer drains before replacement")
    func cancellationDrains() async {
        let lifetime = HerdrProbeLifetime()
        let drain = HerdrProbeGate()
        let broker = drainingBroker(lifetime: lifetime, drain: drain)

        let first = Task { await broker.sessions(on: .local) }
        await waitUntilMainActor { lifetime.snapshot.starts == 1 }
        first.cancel()
        #expect(await first.value == .failure(.cancelled(host: "localhost")))

        let replacement = Task { await broker.sessions(on: .local) }
        try? await Task.sleep(for: .milliseconds(25))
        #expect(lifetime.snapshot.starts == 1)

        await drain.open()
        #expect(await replacement.value == .available([]))
        #expect(lifetime.snapshot.maximumActive == 1)
    }

    @MainActor
    @Test("exact names distinguish present, absent, unavailable, and failure")
    func exactNameOutcomes() async {
        let error = HerdrCommandError.commandFailed(
            status: 42,
            stderr: "broken"
        )
        let results: [(HerdrDiscoveryResult, HerdrSessionProbeOutcome)] = [
            (.available([HerdrSessionSummary(
                name: "api",
                isDefault: false,
                state: .running
            )]), .present),
            (.available([HerdrSessionSummary(
                name: "api",
                isDefault: false,
                state: .stopped
            )]), .absent),
            (.available([]), .absent),
            (.unavailable, .unavailable),
            (.failure(error), .failure(error)),
        ]

        for (discovery, expected) in results {
            let broker = HerdrSessionProbeBroker { _ in discovery }
            #expect(await broker.session(named: "api", on: .local) == expected)
        }
    }

    @MainActor
    private func drainingBroker(
        lifetime: HerdrProbeLifetime,
        drain: HerdrProbeGate
    ) -> HerdrSessionProbeBroker {
        HerdrSessionProbeBroker { _ in
            let call = lifetime.begin()
            guard call == 1 else {
                lifetime.end()
                return .available([])
            }
            do {
                try await Task.sleep(for: .seconds(10))
                lifetime.end()
                return .available([])
            } catch {
                await drain.wait()
                lifetime.end(cancelled: true)
                return .failure(.cancelled(host: "localhost"))
            }
        }
    }
}
