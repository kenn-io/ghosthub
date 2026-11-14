import Foundation
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("kwt SSH terminal placement")
struct KwtSSHTerminalPlacementTests {
    private static let request = KwtSSHDestinationRequest(
        destination: "build.example.test",
        host: SSHHostInfo(user: nil, hostname: "build.example.test", port: nil)
    )

    private static func socket(_ lane: Int) -> String {
        "/private/master-\(lane).sock"
    }

    private static func controlPath(_ connection: KwtSSHConnection) -> String? {
        SSHSessionBudget.controlPath(in: connection.arguments)
    }

    /// Lanes whose leases each name their own master socket, counting how
    /// many times each lane leased a master.
    private static func lanes(
        leases: LockedValue<[Int: Int]>
    ) -> KwtSSHConnectionLanes {
        KwtSSHConnectionLanes(
            primary: pool(lane: 0, leases: leases),
            makePool: { pool(lane: $0, leases: leases) }
        )
    }

    private static func pool(
        lane: Int,
        leases: LockedValue<[Int: Int]>
    ) -> KwtSSHConnectionPool {
        KwtSSHConnectionPool { route, _ in
            leases.withLock { $0[lane, default: 0] += 1 }
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-F", "/dev/null", "-S", socket(lane)]
            )
        }
    }

    /// Opens one command session that stays open until the returned closure
    /// runs, then reports a refusal for a second command beside it.
    private static func refuseBesideOneOpenSession(
        budget: SSHSessionBudget,
        arguments: [String]
    ) -> @Sendable () -> Void {
        let held = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = budget.run(arguments: arguments, timeout: 5, retryRefusal: false) { _ in
                started.signal()
                held.wait()
                return AccountCommandOutput(status: 0, stdout: "", stderr: "")
            }
        }
        started.wait()
        _ = budget.run(arguments: arguments, timeout: 5, retryRefusal: false) { _ in
            AccountCommandOutput(
                status: 255,
                stdout: "",
                stderr: "mux_client_request_session: session request failed: "
                    + "Session open refused by peer"
            )
        }
        return { held.signal() }
    }

    private static func coordinator(
        lanes: KwtSSHConnectionLanes,
        budget: SSHSessionBudget,
        routeIdentity: LockedValue<String> = LockedValue("sha256:placement")
    ) -> KwtSSHAcquisitionCoordinator {
        KwtSSHAcquisitionCoordinator(
            resolve: { _ in .fixture(routeIdentity: routeIdentity.load()) },
            lanes: lanes,
            budget: budget
        )
    }

    /// Places a terminal and launches it, as a presentation does after its
    /// setup probes.
    private static func launchedTerminal(
        _ coordinator: KwtSSHAcquisitionCoordinator
    ) async throws -> KwtSSHConnection {
        let connection = try await acquire(coordinator, purpose: .terminal)
        try await connection.activateSessionReservation()
        return connection
    }

    /// Reports a refusal beside what is open now, so the budget learns that
    /// the server allows nothing more on this master.
    private static func refuseNextSession(
        budget: SSHSessionBudget,
        arguments: [String]
    ) async {
        _ = await Task.detached {
            budget.run(arguments: arguments, timeout: 5, retryRefusal: false) { _ in
                AccountCommandOutput(
                    status: 255,
                    stdout: "",
                    stderr: "mux_client_request_session: session request failed: "
                        + "Session open refused by peer"
                )
            }
        }.value
    }

    private static func acquire(
        _ coordinator: KwtSSHAcquisitionCoordinator,
        purpose: KwtSSHConnectionPurpose
    ) async throws -> KwtSSHConnection {
        try await coordinator.acquire(
            request: request,
            subscriberID: UUID(),
            canPresentPrompts: true,
            purpose: purpose,
            prompt: { _, _ in "" }
        )
    }

    @Test("terminals open another master once the first holds its share")
    func terminalsSpillToAnotherMaster() async throws {
        let leases = LockedValue<[Int: Int]>([:])
        let budget = SSHSessionBudget()
        let coordinator = Self.coordinator(
            lanes: Self.lanes(leases: leases),
            budget: budget
        )
        let share = SSHSessionBudget.terminalLimit(
            capacity: SSHSessionBudget.defaultCapacity
        )

        var terminals: [KwtSSHConnection] = []
        for _ in 0 ..< share + 2 {
            try await terminals.append(Self.launchedTerminal(coordinator))
        }

        let paths = terminals.map(Self.controlPath)
        #expect(paths.prefix(share).allSatisfy { $0 == Self.socket(0) })
        #expect(paths.suffix(2).allSatisfy { $0 == Self.socket(1) })
        #expect(leases.load() == [0: 1, 1: 1])
        #expect(budget.openSessions(forControlPath: Self.socket(0)) == share)

        let command = try await Self.acquire(coordinator, purpose: .commands)
        #expect(Self.controlPath(command) == Self.socket(0))
        try await command.release()

        try await terminals.removeFirst().release()
        let reopened = try await Self.acquire(coordinator, purpose: .terminal)
        #expect(Self.controlPath(reopened) == Self.socket(0))
        terminals.append(reopened)

        for terminal in terminals {
            try await terminal.release()
        }
        #expect(budget.openSessions(forControlPath: Self.socket(0)) == 0)
        #expect(budget.openSessions(forControlPath: Self.socket(1)) == 0)
    }

    @Test("a master with a learned lower limit takes fewer terminals")
    func learnedLimitMovesTerminalsSooner() async throws {
        let leases = LockedValue<[Int: Int]>([:])
        let budget = SSHSessionBudget(sleep: { _ in })
        let coordinator = Self.coordinator(
            lanes: Self.lanes(leases: leases),
            budget: budget
        )
        let first = try await Self.launchedTerminal(coordinator)
        // A command refused while the terminal and one more command were
        // open teaches the budget that the server allows only two sessions.
        let arguments = first.arguments
        let releaseHeld = await Task.detached {
            Self.refuseBesideOneOpenSession(budget: budget, arguments: arguments)
        }.value
        releaseHeld()
        #expect(budget.capacity(forControlPath: Self.socket(0)) == 2)

        let second = try await Self.acquire(coordinator, purpose: .terminal)

        #expect(Self.controlPath(second) == Self.socket(1))
        try await first.release()
        try await second.release()
    }

    @Test("a pane command stranded on a full master runs on another master of its route")
    func strandedAttachmentCommandOverflows() async throws {
        let leases = LockedValue<[Int: Int]>([:])
        let budget = SSHSessionBudget(sleep: { _ in })
        let coordinator = Self.coordinator(
            lanes: Self.lanes(leases: leases),
            budget: budget
        )
        let terminal = try await Self.launchedTerminal(coordinator)
        // The server allows only the terminal's session on the first master.
        let arguments = terminal.arguments
        await Self.refuseNextSession(budget: budget, arguments: arguments)
        let used = LockedValue<[String?]>([])

        // A split or paste uses the attachment's own arguments.
        let output = await Task.detached {
            budget.run(arguments: arguments, timeout: 5, retryRefusal: false) {
                arguments in
                used.withLock { $0.append(SSHSessionBudget.controlPath(in: arguments)) }
                return AccountCommandOutput(status: 0, stdout: "ran\n", stderr: "")
            }
        }.value

        #expect(output.stdout == "ran\n")
        #expect(used.load() == [Self.socket(1)])
        let command = try await Self.acquire(coordinator, purpose: .commands)
        #expect(Self.controlPath(command) == Self.socket(1))
        try await command.release()
        try await terminal.release()
    }

    @Test("a stranded command never runs on a master of a different route")
    func overflowKeepsTheRouteIdentity() async throws {
        let leases = LockedValue<[Int: Int]>([:])
        let budget = SSHSessionBudget(sleep: { _ in })
        let routeIdentity = LockedValue("sha256:placement")
        let coordinator = Self.coordinator(
            lanes: Self.lanes(leases: leases),
            budget: budget,
            routeIdentity: routeIdentity
        )
        let terminal = try await Self.launchedTerminal(coordinator)
        let arguments = terminal.arguments
        await Self.refuseNextSession(budget: budget, arguments: arguments)
        // The destination now resolves to another route.
        routeIdentity.store("sha256:changed")
        let ran = LockedValue(false)

        let output = await Task.detached {
            budget.run(arguments: arguments, timeout: 5, retryRefusal: false) { _ in
                ran.store(true)
                return AccountCommandOutput(status: 0, stdout: "", stderr: "")
            }
        }.value

        #expect(output.stderr == SSHSessionBudget.terminalsFullMessage)
        #expect(ran.load() == false)
        try await terminal.release()
    }

    @Test("a command group that succeeded is not replayed when another command is stranded")
    func succeededOperationIsNotReplayed() async throws {
        let leases = LockedValue<[Int: Int]>([:])
        let budget = SSHSessionBudget(sleep: { _ in })
        let coordinator = Self.coordinator(
            lanes: Self.lanes(leases: leases),
            budget: budget
        )
        let terminal = try await Self.launchedTerminal(coordinator)
        let lease = KwtSSHCommandLease { _ in
            try await Self.acquire(coordinator, purpose: .commands)
        }
        let runs = LockedValue(0)
        let terminalArguments = terminal.arguments

        _ = try await lease.withArguments(on: .ssh(Self.request.host)) { arguments in
            runs.withLock { $0 += 1 }
            let arguments = arguments ?? []
            _ = await BlockingTask.run {
                budget.run(arguments: arguments, timeout: 5, retryRefusal: false) { _ in
                    AccountCommandOutput(status: 0, stdout: "renamed\n", stderr: "")
                }
            }
            // Meanwhile another caller learns the master is full and is
            // turned away from it.
            await Self.refuseNextSession(budget: budget, arguments: terminalArguments)
            _ = await BlockingTask.run {
                budget.run(arguments: terminalArguments, timeout: 5, retryRefusal: false) { _ in
                    AccountCommandOutput(status: 0, stdout: "", stderr: "")
                }
            }
        }

        #expect(runs.load() == 1)
        try await terminal.release()
    }

    /// A window that shows one prompt at a time, as a connection session
    /// does: a second prompt while one is open is rejected.
    private final class PromptWindow: @unchecked Sendable {
        private let lock = NSLock()
        private var showing = false
        private(set) var overlaps = 0
        let firstShown = DispatchSemaphore(value: 0)
        let answerFirst = DispatchSemaphore(value: 0)
        private var shownCount = 0

        static func waitOffPool(_ semaphore: DispatchSemaphore) async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    semaphore.wait()
                    continuation.resume()
                }
            }
        }

        func present(_ prompt: KwtSSHLeasePrompt) async throws -> String {
            let first = lock.withLock {
                if showing {
                    overlaps += 1
                    return Bool?.none
                }
                showing = true
                shownCount += 1
                return shownCount == 1
            }
            guard let first else { throw KwtSSHLeaseError.malformedEvent }
            defer { lock.withLock { showing = false } }
            if first {
                firstShown.signal()
                await Self.waitOffPool(answerFirst)
            }
            return "secret"
        }
    }

    private static func passwordPrompt(_ id: String) -> KwtSSHLeasePrompt {
        let target = KwtSSHTarget(hostname: "build.example.test")
        return KwtSSHLeasePrompt(
            id: id,
            kind: .authentication,
            message: "Password:",
            sensitive: true,
            deadline: "2099-08-15T12:00:00Z",
            details: KwtSSHLeasePromptDetails(
                logicalTarget: target,
                effectiveTarget: target,
                displayTarget: "build.example.test",
                hopIndex: 0,
                hopCount: 1,
                hostKey: nil
            )
        )
    }

    @Test("prompts from two masters of one route take turns")
    func promptsForOneRouteAreSerialized() async throws {
        let budget = SSHSessionBudget(sleep: { _ in })
        let primaryLeases = LockedValue(0)
        // The primary master authenticates silently the first time and asks
        // for a password when it reconnects; the second always asks.
        let lanes = KwtSSHConnectionLanes(
            primary: KwtSSHConnectionPool { route, prompt in
                primaryLeases.withLock { $0 += 1 }
                let count = primaryLeases.load()
                if count > 1 {
                    _ = try await prompt(Self.passwordPrompt("primary"))
                }
                return KwtSSHTestLease(
                    routeIdentity: route.routeIdentity,
                    arguments: ["-F", "/dev/null", "-S", Self.socket(0)]
                )
            },
            makePool: { lane in
                KwtSSHConnectionPool { route, prompt in
                    _ = try await prompt(Self.passwordPrompt("lane-\(lane)"))
                    return KwtSSHTestLease(
                        routeIdentity: route.routeIdentity,
                        arguments: ["-F", "/dev/null", "-S", Self.socket(lane)]
                    )
                }
            }
        )
        let coordinator = Self.coordinator(lanes: lanes, budget: budget)
        let window = PromptWindow()
        func acquire(_ purpose: KwtSSHConnectionPurpose) async throws -> KwtSSHConnection {
            try await coordinator.acquire(
                request: Self.request,
                subscriberID: UUID(),
                canPresentPrompts: true,
                purpose: purpose,
                prompt: { _, prompt in try await window.present(prompt) }
            )
        }
        // One terminal fills the primary master once its one-session limit
        // is learned, so the next terminal needs the second master.
        let terminal = try await Self.launchedTerminal(coordinator)
        await Self.refuseNextSession(budget: budget, arguments: terminal.arguments)

        let second = Task { try await acquire(.terminal) }
        await PromptWindow.waitOffPool(window.firstShown)
        // While the second master waits for its password, the primary
        // master drops and must authenticate again.
        await terminal.invalidate()
        let reconnect = Task { try await acquire(.commands) }
        try await Task.sleep(for: .milliseconds(200))
        window.answerFirst.signal()

        let secondConnection = try await second.value
        let reconnected = try await reconnect.value
        #expect(window.overlaps == 0)
        #expect(Self.controlPath(secondConnection) == Self.socket(1))
        #expect(Self.controlPath(reconnected) != nil)
        try await secondConnection.release()
        try await reconnected.release()
        try await terminal.release()
    }

    @Test("more stranded commands than worker threads all reach another master")
    func strandedCommandsBeyondTheWorkerPoolOverflow() async throws {
        let leases = LockedValue<[Int: Int]>([:])
        let budget = SSHSessionBudget(sleep: { _ in })
        let coordinator = Self.coordinator(
            lanes: Self.lanes(leases: leases),
            budget: budget
        )
        let terminal = try await Self.launchedTerminal(coordinator)
        let arguments = terminal.arguments
        await Self.refuseNextSession(budget: budget, arguments: arguments)
        // Enough waiting commands to occupy every shared worker thread, so
        // leasing the other master must not need one of them.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2 + 2
        let started = Date()

        let outputs = await withTaskGroup(of: String?.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    await BlockingTask.run {
                        budget.run(arguments: arguments, timeout: 20, retryRefusal: false) {
                            arguments in
                            AccountCommandOutput(
                                status: 0,
                                stdout: SSHSessionBudget.controlPath(in: arguments) ?? "",
                                stderr: ""
                            )
                        }
                    }.stdout
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(outputs == Array(repeating: Self.socket(1), count: count))
        #expect(Date().timeIntervalSince(started) < 10)
        try await terminal.release()
    }

    @MainActor
    @Test("presentation checks that only run commands leave terminal places alone")
    func presentationCommandChecksKeepToTheTerminalsMaster() async throws {
        let leases = LockedValue<[Int: Int]>([:])
        let budget = SSHSessionBudget(sleep: { _ in })
        let coordinator = Self.coordinator(
            lanes: Self.lanes(leases: leases),
            budget: budget
        )
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            presentationSSHConnectionProvider: nil,
            presentationSSHAcquisitionCoordinator: coordinator
        )
        // Terminals take every terminal place on the first master, which
        // still keeps sessions free for commands.
        let share = SSHSessionBudget.terminalLimit(
            capacity: SSHSessionBudget.defaultCapacity
        )
        var terminals: [KwtSSHConnection] = []
        for _ in 0 ..< share {
            let terminal = try await model.acquirePresentationSSHConnection(
                hostID: UUID(),
                info: Self.request.host
            )
            try await terminal.activateSessionReservation()
            terminals.append(terminal)
        }
        #expect(terminals.allSatisfy { Self.controlPath($0) == Self.socket(0) })

        // A reconnect probe needs a session, not a terminal place, so it
        // stays on that master instead of opening (and authenticating)
        // another one.
        let check = try await model.acquirePresentationSSHConnection(
            hostID: UUID(),
            info: Self.request.host,
            purpose: .commands
        )

        #expect(Self.controlPath(check) == Self.socket(0))
        #expect(leases.load()[1] == nil)
        try await check.release()
        for terminal in terminals {
            try await terminal.release()
        }
        await model.shutdown()
    }
}
