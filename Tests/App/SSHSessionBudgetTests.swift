import Foundation
import Testing
@testable import GhosthubApp

@Suite("SSH session budget")
struct SSHSessionBudgetTests {
    private static let socket = "/private/master.sock"
    private static let arguments = ["-F", "/dev/null", "-S", socket]
    private static let otherArguments = ["-F", "/dev/null", "-S", "/private/other.sock"]
    private static let refused = AccountCommandOutput(
        status: 255,
        stdout: "",
        stderr: """
        mux_client_request_session: session request failed: Session open refused by peer
        Connection closed by UNKNOWN port 65535
        """
    )
    private static let succeeded = AccountCommandOutput(status: 0, stdout: "ok\n", stderr: "")

    /// An sshd that refuses sessions beyond `maxSessions` on one connection.
    private final class FakeServer: @unchecked Sendable {
        let maxSessions: Int
        private let lock = NSLock()
        private var open = 0
        private(set) var peak = 0
        private(set) var refusals = 0

        init(maxSessions: Int) {
            self.maxSessions = maxSessions
        }

        /// Accepts a session and holds it for `duration`, then for as long as
        /// `holdWhile` is true (bounded), so a test can keep the server at its
        /// limit however the machine schedules the callers.
        func session(
            holding duration: TimeInterval = 0.05,
            holdWhile: () -> Bool = { false }
        ) -> AccountCommandOutput {
            let accepted = lock.withLock {
                guard open < maxSessions else {
                    refusals += 1
                    return false
                }
                open += 1
                peak = max(peak, open)
                return true
            }
            guard accepted else { return SSHSessionBudgetTests.refused }
            Thread.sleep(forTimeInterval: duration)
            let deadline = Date().addingTimeInterval(5)
            while holdWhile(), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            lock.withLock { open -= 1 }
            return SSHSessionBudgetTests.succeeded
        }

        /// Holds sessions outside any command, as open terminals do.
        func openLongLived(_ count: Int) {
            lock.withLock {
                open += count
                peak = max(peak, open)
            }
        }
    }

    private static func runConcurrently(
        _ count: Int,
        _ body: @escaping @Sendable (Int) -> AccountCommandOutput
    ) -> [AccountCommandOutput] {
        // One thread per caller: a dispatch pool would run only as many
        // callers at once as the machine has cores.
        let results = LockedValue<[Int: AccountCommandOutput]>([:])
        let finished = DispatchGroup()
        for index in 0 ..< count {
            finished.enter()
            Thread.detachNewThread {
                let output = body(index)
                results.withLock { $0[index] = output }
                finished.leave()
            }
        }
        finished.wait()
        return (0 ..< count).compactMap { results.load()[$0] }
    }

    /// Starts `count` commands that hold their sessions until released, and
    /// returns once all of them run. The returned closure lets them finish
    /// and waits until their sessions are back in the budget.
    private static func holdSessions(
        _ count: Int,
        on budget: SSHSessionBudget
    ) -> @Sendable () -> Void {
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        for _ in 0 ..< count {
            finished.enter()
            Thread.detachNewThread {
                _ = budget.run(arguments: arguments, timeout: 10, retryRefusal: false) { _ in
                    started.signal()
                    release.wait()
                    return succeeded
                }
                finished.leave()
            }
        }
        for _ in 0 ..< count {
            started.wait()
        }
        return {
            for _ in 0 ..< count {
                release.signal()
            }
            finished.wait()
        }
    }

    /// Places and launches one terminal.
    private static func launchedTerminal(
        on budget: SSHSessionBudget
    ) async throws -> SSHSessionReservation {
        let reservation = try #require(budget.reserveTerminal(arguments: arguments))
        #expect(await reservation.activate())
        return reservation
    }

    /// Teaches the budget that the server allows only the sessions that are
    /// open now, by reporting a refusal for one more command.
    private static func refuseNextSession(on budget: SSHSessionBudget) async {
        _ = await Task.detached {
            budget.run(arguments: arguments, timeout: 5, retryRefusal: false) { _ in
                refused
            }
        }.value
    }

    @Test("commands beyond a master's capacity wait for a free session")
    func commandsQueueAtCapacity() {
        let budget = SSHSessionBudget()
        let server = FakeServer(maxSessions: SSHSessionBudget.defaultCapacity)

        let outputs = Self.runConcurrently(25) { _ in
            budget.run(arguments: Self.arguments, timeout: 10, retryRefusal: false) { _ in
                server.session()
            }
        }

        #expect(outputs.allSatisfy { $0.status == 0 })
        #expect(server.refusals == 0)
        #expect(server.peak <= SSHSessionBudget.defaultCapacity)
        #expect(budget.openSessions(forControlPath: Self.socket) == 0)
    }

    @Test("a server with a lower session limit is learned and retried")
    func learnsLowerServerLimit() {
        let budget = SSHSessionBudget(sleep: { _ in })
        let server = FakeServer(maxSessions: 4)

        let outputs = Self.runConcurrently(12) { _ in
            budget.run(arguments: Self.arguments, timeout: 10, retryRefusal: true) { _ in
                // Stay at the server's limit until the budget has learned it.
                server.session {
                    budget.capacity(forControlPath: Self.socket) > server.maxSessions
                }
            }
        }

        #expect(outputs.allSatisfy { $0.status == 0 })
        #expect(server.refusals > 0)
        #expect(server.peak <= 4)
        #expect(budget.capacity(forControlPath: Self.socket) == 4)
    }

    @Test("commands that may not repeat report a refusal without running again")
    func nonRepeatableCommandIsNotRetried() {
        let budget = SSHSessionBudget(sleep: { _ in })
        let attempts = LockedValue(0)

        let output = budget.run(
            arguments: Self.arguments,
            timeout: 10,
            retryRefusal: false
        ) { _ in
            attempts.withLock { $0 += 1 }
            return Self.refused
        }

        #expect(output.status == 255)
        #expect(attempts.load() == 1)
    }

    @Test("a refusal with nothing else open backs off without lowering capacity")
    func refusalFromUncountedSessionsBacksOff() {
        let delays = LockedValue<[TimeInterval]>([])
        let budget = SSHSessionBudget(sleep: { delay in
            delays.withLock { $0.append(delay) }
        })
        let attempts = LockedValue(0)

        let output = budget.run(
            arguments: Self.arguments,
            timeout: 10,
            retryRefusal: true
        ) { _ in
            attempts.withLock { $0 += 1 }
            return attempts.load() < 3 ? Self.refused : Self.succeeded
        }

        #expect(output.status == 0)
        #expect(attempts.load() == 3)
        #expect(delays.load() == [0.25, 0.5])
        #expect(budget.capacity(forControlPath: Self.socket)
            == SSHSessionBudget.defaultCapacity)
    }

    @Test("persistent refusals stop after a bounded number of attempts")
    func persistentRefusalIsBounded() {
        let budget = SSHSessionBudget(sleep: { _ in })
        let attempts = LockedValue(0)

        let output = budget.run(
            arguments: Self.arguments,
            timeout: 10,
            retryRefusal: true
        ) { _ in
            attempts.withLock { $0 += 1 }
            return Self.refused
        }

        #expect(output.status == 255)
        #expect(attempts.load() == SSHSessionBudget.maximumRefusalAttempts)
    }

    @Test("terminals fill a master only up to their share")
    func terminalsLeaveRoomForCommands() async throws {
        let budget = SSHSessionBudget()
        let limit = SSHSessionBudget.terminalLimit(
            capacity: SSHSessionBudget.defaultCapacity
        )
        var reservations: [SSHSessionReservation] = []
        for _ in 0 ..< limit {
            try await reservations.append(Self.launchedTerminal(on: budget))
        }

        #expect(budget.reserveTerminal(arguments: Self.arguments) == nil)

        let server = FakeServer(maxSessions: SSHSessionBudget.defaultCapacity)
        server.openLongLived(limit)
        let outputs = Self.runConcurrently(8) { _ in
            budget.run(arguments: Self.arguments, timeout: 10, retryRefusal: false) { _ in
                server.session()
            }
        }
        #expect(outputs.allSatisfy { $0.status == 0 })
        #expect(server.refusals == 0)

        reservations.removeLast().release()
        #expect(budget.reserveTerminal(arguments: Self.arguments) != nil)
    }

    @Test("a placed terminal's setup probe runs before its session counts")
    func setupProbeRunsBesideAPlacedTerminal() async throws {
        let budget = SSHSessionBudget(sleep: { _ in })
        // One open command and a refusal teach the budget that the server
        // allows a single session on this master.
        let releaseHeld = Self.holdSessions(1, on: budget)
        await Self.refuseNextSession(on: budget)
        releaseHeld()
        #expect(budget.capacity(forControlPath: Self.socket) == 1)

        let reservation = try #require(budget.reserveTerminal(arguments: Self.arguments))
        let probe = await Task.detached {
            budget.run(arguments: Self.arguments, timeout: 5, retryRefusal: false) { _ in
                Self.succeeded
            }
        }.value

        #expect(probe == Self.succeeded)
        #expect(budget.openSessions(forControlPath: Self.socket) == 0)
        #expect(await reservation.activate())
        #expect(budget.openSessions(forControlPath: Self.socket) == 1)
        reservation.release()
        #expect(budget.openSessions(forControlPath: Self.socket) == 0)
    }

    @Test("a released terminal admits a waiting command")
    func releasedTerminalAdmitsCommand() async throws {
        let budget = SSHSessionBudget()
        let reservation = try await Self.launchedTerminal(on: budget)
        let releaseBusy = Self.holdSessions(
            SSHSessionBudget.defaultCapacity - 1,
            on: budget
        )

        let waiting = Task.detached {
            budget.run(arguments: Self.arguments, timeout: 10, retryRefusal: false) { _ in
                AccountCommandOutput(status: 0, stdout: "late\n", stderr: "")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        reservation.release()

        #expect(await waiting.value.stdout == "late\n")
        releaseBusy()
    }

    @Test("a command reports a timeout when no session frees in time")
    func queuedCommandTimesOut() {
        let budget = SSHSessionBudget()
        let releaseBusy = Self.holdSessions(SSHSessionBudget.defaultCapacity, on: budget)
        let ran = LockedValue(false)

        let output = budget.run(arguments: Self.arguments, timeout: 0.2, retryRefusal: true) { _ in
            ran.store(true)
            return Self.succeeded
        }

        #expect(output.stderr == SSHSessionBudget.queueTimeoutMessage)
        #expect(ran.load() == false)
        releaseBusy()
    }

    @Test("a cancelled queued command returns without running or holding a session")
    func cancelledQueuedCommandStopsWaiting() async {
        let budget = SSHSessionBudget()
        let releaseBusy = Self.holdSessions(SSHSessionBudget.defaultCapacity, on: budget)
        let ran = LockedValue(false)
        let started = Date()

        let queued = Task {
            await BlockingTask.run {
                budget.run(arguments: Self.arguments, timeout: 30, retryRefusal: false) { _ in
                    ran.store(true)
                    return Self.succeeded
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        queued.cancel()
        let output = await queued.value

        #expect(output == SSHSessionBudget.cancelledOutput)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(ran.load() == false)
        releaseBusy()
        #expect(budget.openSessions(forControlPath: Self.socket) == 0)
    }

    @Test("a command cancelled just before its session frees up never runs")
    func commandCancelledBeforeItsGrantStaysStopped() async {
        let budget = SSHSessionBudget()
        let releaseBusy = Self.holdSessions(SSHSessionBudget.defaultCapacity, on: budget)
        let ran = LockedValue(false)

        let queued = Task {
            await BlockingTask.run {
                budget.run(arguments: Self.arguments, timeout: 30, retryRefusal: false) { _ in
                    ran.store(true)
                    return Self.succeeded
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        // The session frees up right after the cancel, well inside one
        // cancellation poll, so the grant is what wakes the command.
        queued.cancel()
        releaseBusy()
        let output = await queued.value

        #expect(output == SSHSessionBudget.cancelledOutput)
        #expect(ran.load() == false)
        #expect(budget.openSessions(forControlPath: Self.socket) == 0)
    }

    @Test("cancelling terminal launches never loses a session or a place")
    func cancelledActivationsReturnEverything() async throws {
        let budget = SSHSessionBudget()
        // A full master makes each launch wait, so cancellation lands at
        // every point between registering and granting.
        let releaseBusy = Self.holdSessions(SSHSessionBudget.defaultCapacity, on: budget)
        for attempt in 0 ..< 200 {
            let reservation = try #require(budget.reserveTerminal(arguments: Self.arguments))
            let launch = Task { await reservation.activate() }
            if attempt.isMultiple(of: 2) {
                await Task.yield()
            }
            launch.cancel()
            #expect(await launch.value == false)
            reservation.release()
        }
        releaseBusy()

        #expect(budget.openSessions(forControlPath: Self.socket) == 0)
        let limit = SSHSessionBudget.terminalLimit(capacity: SSHSessionBudget.defaultCapacity)
        var reservations: [SSHSessionReservation] = []
        for _ in 0 ..< limit {
            try await reservations.append(Self.launchedTerminal(on: budget))
        }
        #expect(budget.openSessions(forControlPath: Self.socket) == limit)
    }

    @Test("a command stranded by terminals runs once on another master of the route")
    func strandedCommandOverflowsToAnotherMaster() async throws {
        let budget = SSHSessionBudget(sleep: { _ in })
        let terminal = try await Self.launchedTerminal(on: budget)
        // The server turns out to allow only the terminal's session.
        await Self.refuseNextSession(on: budget)
        #expect(budget.hasCommandRoom(arguments: Self.arguments) == false)
        let releases = LockedValue(0)
        budget.registerOverflow(arguments: Self.arguments) { _ in
            SSHSessionBudget.Overflow(
                arguments: Self.otherArguments,
                release: { releases.withLock { $0 += 1 } }
            )
        }
        let used = LockedValue<[[String]]>([])

        let output = await Task.detached {
            budget.run(arguments: Self.arguments, timeout: 5, retryRefusal: false) {
                arguments in
                used.withLock { $0.append(arguments) }
                return Self.succeeded
            }
        }.value

        #expect(output == Self.succeeded)
        #expect(used.load() == [Self.otherArguments])
        #expect(releases.load() == 1)
        #expect(budget.openSessions(forControlPath: "/private/other.sock") == 0)
        terminal.release()
    }

    @Test("a stranded command without another master reports the full connection")
    func strandedCommandWithoutOverflowFails() async throws {
        let budget = SSHSessionBudget(sleep: { _ in })
        let terminal = try await Self.launchedTerminal(on: budget)
        await Self.refuseNextSession(on: budget)
        let ran = LockedValue(false)

        let output = await Task.detached {
            budget.run(arguments: Self.arguments, timeout: 5, retryRefusal: true) { _ in
                ran.store(true)
                return Self.succeeded
            }
        }.value

        #expect(output.stderr == SSHSessionBudget.terminalsFullMessage)
        #expect(ran.load() == false)
        terminal.release()
    }

    @Test("arguments without a control socket run without counting")
    func unbudgetedArgumentsRunImmediately() {
        let budget = SSHSessionBudget()

        let output = budget.run(
            arguments: ["-F", "/dev/null"],
            timeout: 1,
            retryRefusal: false
        ) { _ in
            Self.succeeded
        }

        #expect(output.status == 0)
        #expect(budget.reserveTerminal(arguments: ["-F", "/dev/null"]) != nil)
    }
}
