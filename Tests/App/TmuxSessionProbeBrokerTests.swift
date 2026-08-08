import GhosthubTransport
import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class ProbeLifetimeCounter: @unchecked Sendable {
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

    var snapshot: (starts: Int, maximumActive: Int, cancellations: Int) {
        lock.withLock { (starts, maximumActive, cancellations) }
    }
}

private actor ProbeGate {
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

@Suite("Tmux session probe broker")
struct TmuxSessionProbeBrokerTests {
    @MainActor
    @Test("concurrent default-socket consumers share one discovery")
    func coalescesDefaultDiscovery() async {
        let calls = ProbeCounter()
        let gate = ProbeGate()
        let broker = TmuxSessionProbeBroker(
            discover: { _ in
                calls.increment()
                await gate.wait()
                return .success([])
            },
            exactProbe: { _ in .success(false) }
        )

        async let first = broker.sessions(on: .local)
        async let second = broker.sessions(on: .local)
        await gate.waitUntilBlocked()
        await Task.yield()
        await gate.open()
        _ = await (first, second)

        #expect(calls.count == 1)
    }

    @MainActor
    @Test("distinct protected sessions keep distinct exact probes")
    func keepsProtectedTargetsDistinct() async {
        let calls = ProbeCounter()
        let gate = ProbeGate()
        let host = SSHHostInfo(
            user: "wesm",
            hostname: "build-box",
            port: nil
        )
        let broker = TmuxSessionProbeBroker(
            discover: { _ in .success([]) },
            exactProbe: { _ in
                calls.increment()
                await gate.wait()
                return .success(true)
            }
        )

        async let first = broker.session(TmuxSessionProbeTarget(
            host: host,
            name: "first",
            socketName: "kwt-first"
        ))
        async let second = broker.session(TmuxSessionProbeTarget(
            host: host,
            name: "second",
            socketName: "kwt-second"
        ))
        await gate.waitUntilBlocked(count: 2)
        await gate.open()

        #expect(await first == .present)
        #expect(await second == .present)
        #expect(calls.count == 2)
    }

    @MainActor
    @Test("completed discovery does not remain cached")
    func removesCompletedDiscovery() async {
        let calls = ProbeCounter()
        let broker = TmuxSessionProbeBroker(
            discover: { _ in
                calls.increment()
                return .success([])
            },
            exactProbe: { _ in .success(false) }
        )

        _ = await broker.sessions(on: .local)
        _ = await broker.sessions(on: .local)

        #expect(calls.count == 2)
    }

    @MainActor
    @Test("a cancelled sole consumer drains before its successor starts")
    func cancellationDrainsBeforeSuccessor() async {
        let lifetime = ProbeLifetimeCounter()
        let cancellationDrain = ProbeGate()
        let broker = TmuxSessionProbeBroker(
            discover: { _ in
                let call = lifetime.begin()
                guard call == 1 else {
                    lifetime.end()
                    return .success([])
                }
                do {
                    try await Task.sleep(for: .seconds(10))
                    lifetime.end()
                    return .success([])
                } catch {
                    await cancellationDrain.wait()
                    lifetime.end(cancelled: true)
                    return .failure(.probeCancelled(shell: "localhost"))
                }
            },
            exactProbe: { _ in .success(false) }
        )

        let first = Task { await broker.sessions(on: .local) }
        await waitUntil { lifetime.snapshot.starts == 1 }
        first.cancel()
        #expect(
            await first.value
                == .failure(.probeCancelled(shell: "localhost"))
        )

        let second = Task { await broker.sessions(on: .local) }
        try? await Task.sleep(for: .milliseconds(25))
        #expect(lifetime.snapshot.starts == 1)
        #expect(lifetime.snapshot.maximumActive == 1)

        await cancellationDrain.open()
        #expect(await second.value == .success([]))
        #expect(lifetime.snapshot.starts == 2)
        #expect(lifetime.snapshot.maximumActive == 1)
        #expect(lifetime.snapshot.cancellations == 1)
    }

    @MainActor
    @Test("invalidation drains before a replacement discovery starts")
    func invalidationDrainsBeforeReplacement() async {
        let lifetime = ProbeLifetimeCounter()
        let cancellationDrain = ProbeGate()
        let broker = TmuxSessionProbeBroker(
            discover: { _ in
                let call = lifetime.begin()
                guard call == 1 else {
                    lifetime.end()
                    return .success([])
                }
                do {
                    try await Task.sleep(for: .seconds(10))
                    lifetime.end()
                    return .success([])
                } catch {
                    await cancellationDrain.wait()
                    lifetime.end(cancelled: true)
                    return .failure(.probeCancelled(shell: "localhost"))
                }
            },
            exactProbe: { _ in .success(false) }
        )

        let first = Task { await broker.sessions(on: .local) }
        await waitUntil { lifetime.snapshot.starts == 1 }
        broker.invalidateSessions(on: .local)
        #expect(
            await first.value
                == .failure(.probeCancelled(shell: "localhost"))
        )

        let replacement = Task { await broker.sessions(on: .local) }
        try? await Task.sleep(for: .milliseconds(25))
        #expect(lifetime.snapshot.starts == 1)
        #expect(lifetime.snapshot.maximumActive == 1)

        await cancellationDrain.open()
        #expect(await replacement.value == .success([]))
        #expect(lifetime.snapshot.starts == 2)
        #expect(lifetime.snapshot.maximumActive == 1)
        #expect(lifetime.snapshot.cancellations == 1)
    }
}
