import Foundation

/// Counts the SSH sessions Ghosthub has open on each kwt-owned OpenSSH master.
///
/// sshd limits how many sessions one connection may carry (`MaxSessions`,
/// 10 by default), and every multiplexed terminal or command is one session.
/// Commands wait here for a free session instead of being refused by the
/// server, and each terminal holds a session from launch until it closes.
///
/// A terminal claims its place on a master when its connection is placed, but
/// its session counts as open only once the terminal is about to launch, so
/// its own setup probes can run first. Terminals may claim a master only up to
/// `terminalLimit(capacity:)`, so commands keep room; a terminal that does not
/// fit belongs on another master. A command turned away because terminals
/// hold every session moves to another master on the same route when one is
/// registered for its master.
///
/// A master is identified by its control socket (the `-S` argument kwt
/// returns). Arguments without one, such as demo isolation, are not counted.
final class SSHSessionBudget: @unchecked Sendable {
    static let shared = SSHSessionBudget()

    /// OpenSSH's default `MaxSessions`. A server that refuses earlier lowers
    /// its master's capacity to what was actually open.
    static let defaultCapacity = 10
    static let maximumRefusalAttempts = 5
    static let refusalBackoff: [TimeInterval] = [0.25, 0.5, 1, 2]
    static let cancellationPollInterval: TimeInterval = 0.05

    static let queueTimeoutMessage =
        "Timed out waiting for a free SSH session on this host's connection."
    static let terminalsFullMessage =
        "Open terminals are using every session this host's SSH connection "
            + "allows. Close a terminal on this host and try again."
    static let cancelledOutput = AccountCommandOutput(
        status: AccountCommandRunner.cancelledStatus,
        stdout: "",
        stderr: ""
    )

    /// Terminals stop short of capacity so inventory and probe commands keep
    /// a few sessions; tiny capacities still admit one terminal.
    static func terminalLimit(capacity: Int) -> Int {
        max(1, capacity - min(3, capacity / 2))
    }

    static func controlPath(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "-S"),
              arguments.indices.contains(index + 1)
        else { return nil }
        let path = arguments[index + 1]
        return path.isEmpty ? nil : path
    }

    /// Arguments for another master on the same route, owned until
    /// `release` runs.
    struct Overflow: Sendable {
        let arguments: [String]
        let release: @Sendable () -> Void
    }

    /// Finds another master on the same route before `deadline`, or nil.
    /// Called from a blocking thread, never with the budget's lock held.
    typealias OverflowProvider = @Sendable (_ deadline: Date) -> Overflow?

    private enum WaiterKind {
        case command
        case terminalActivation
    }

    /// A queued session request. Every field changes only under the
    /// budget's lock, so registration, cancellation, and grants agree.
    private final class Waiter {
        let kind: WaiterKind
        private let resume: (Bool) -> Void
        var settled = false
        var granted = false

        init(kind: WaiterKind, resume: @escaping (Bool) -> Void) {
            self.kind = kind
            self.resume = resume
        }

        func settle(granted: Bool) {
            guard !settled else { return }
            settled = true
            self.granted = granted
            resume(granted)
        }
    }

    private struct Master {
        var capacity = SSHSessionBudget.defaultCapacity
        /// Sessions Ghosthub has open: commands and launched terminals.
        var open = 0
        /// Terminals placed on this master, launched or not.
        var terminals = 0
        /// Terminals that have launched and hold a session.
        var activeTerminals = 0
        var waiters: [Waiter] = []

        var isIdle: Bool {
            open == 0 && terminals == 0 && waiters.isEmpty
                && capacity == SSHSessionBudget.defaultCapacity
        }
    }

    /// Cancellation state shared with an activation's handler; guarded by
    /// the budget's lock.
    private final class ActivationRegistration: @unchecked Sendable {
        var cancelled = false
        var waiter: Waiter?
    }

    private enum CommandWait {
        case granted
        case cancelled
        case timedOut
        case terminalsHoldEverySession
    }

    private let lock = NSLock()
    private var masters: [String: Master] = [:]
    private var overflowProviders: [String: OverflowProvider] = [:]
    private let sleep: @Sendable (TimeInterval) -> Void

    init(sleep: @escaping @Sendable (TimeInterval) -> Void = {
        Thread.sleep(forTimeInterval: $0)
    }) {
        self.sleep = sleep
    }

    func capacity(forControlPath path: String) -> Int {
        lock.withLock { masters[path]?.capacity ?? Self.defaultCapacity }
    }

    func openSessions(forControlPath path: String) -> Int {
        lock.withLock { masters[path]?.open ?? 0 }
    }

    /// False when launched terminals hold every session the master allows,
    /// so a command there could never start until a terminal closes.
    func hasCommandRoom(arguments: [String]) -> Bool {
        guard let path = Self.controlPath(in: arguments) else { return true }
        return lock.withLock {
            guard let master = masters[path] else { return true }
            return master.activeTerminals < master.capacity
        }
    }

    /// Lets commands on this master move to another master on the same route
    /// when terminals fill it. The latest registration wins.
    func registerOverflow(
        arguments: [String],
        provider: @escaping OverflowProvider
    ) {
        guard let path = Self.controlPath(in: arguments) else { return }
        lock.withLock { overflowProviders[path] = provider }
    }

    /// Runs one short-lived SSH session on a blocking thread, waiting for a
    /// free session on its master. `operation` receives the arguments to use,
    /// which name another master when terminals fill the first one. A
    /// refusal by the server lowers the master's capacity; `retryRefusal`
    /// then queues the command again, which is safe only for commands that
    /// may run twice. Cancelling the calling task stops a queued command
    /// before it starts.
    func run(
        arguments: [String],
        timeout: TimeInterval,
        retryRefusal: Bool,
        operation: ([String]) -> AccountCommandOutput
    ) -> AccountCommandOutput {
        run(
            arguments: arguments,
            deadline: Date().addingTimeInterval(timeout),
            retryRefusal: retryRefusal,
            allowsOverflow: true,
            operation: operation
        )
    }

    private func run(
        arguments: [String],
        deadline: Date,
        retryRefusal: Bool,
        allowsOverflow: Bool,
        operation: ([String]) -> AccountCommandOutput
    ) -> AccountCommandOutput {
        guard let path = Self.controlPath(in: arguments) else {
            return operation(arguments)
        }
        var attempt = 0
        while true {
            attempt += 1
            switch waitForCommandSession(path: path, deadline: deadline) {
            case .granted:
                break
            case .cancelled:
                return Self.cancelledOutput
            case .timedOut:
                return AccountCommandOutput(
                    status: 255,
                    stdout: "",
                    stderr: Self.queueTimeoutMessage
                )
            case .terminalsHoldEverySession:
                // The command never started, so it may run elsewhere.
                guard allowsOverflow,
                      let provider = lock.withLock({ overflowProviders[path] }),
                      let overflow = provider(deadline)
                else {
                    return AccountCommandOutput(
                        status: 255,
                        stdout: "",
                        stderr: Self.terminalsFullMessage
                    )
                }
                defer { overflow.release() }
                return run(
                    arguments: overflow.arguments,
                    deadline: deadline,
                    retryRefusal: retryRefusal,
                    allowsOverflow: false,
                    operation: operation
                )
            }
            let output = operation(arguments)
            guard SSHConnectionFailure.indicatesRefusedSessionOpen(
                status: output.status,
                output: output.stderr
            ) else {
                lock.withLock { releaseCommandLocked(path: path) }
                return output
            }
            let othersOpen = recordRefusal(path: path)
            guard retryRefusal,
                  attempt < Self.maximumRefusalAttempts,
                  Date() < deadline
            else { return output }
            if othersOpen == 0 {
                // Nothing Ghosthub counts was open, so another client of the
                // same master holds the sessions; give it time to finish.
                let delay = Self.refusalBackoff[
                    min(attempt - 1, Self.refusalBackoff.count - 1)
                ]
                sleep(min(delay, max(0, deadline.timeIntervalSinceNow)))
            }
        }
    }

    /// Places a terminal on this master. Returns nil when the master already
    /// holds its share of terminals, so the caller should use another master.
    /// The reservation takes a session only when it is activated.
    func reserveTerminal(arguments: [String]) -> SSHSessionReservation? {
        guard let path = Self.controlPath(in: arguments) else {
            return SSHSessionReservation(path: nil, budget: nil)
        }
        let placed = lock.withLock {
            var master = masters[path] ?? Master()
            guard master.terminals < Self.terminalLimit(capacity: master.capacity)
            else { return false }
            master.terminals += 1
            masters[path] = master
            return true
        }
        return placed ? SSHSessionReservation(path: path, budget: self) : nil
    }

    private func waitForCommandSession(
        path: String,
        deadline: Date
    ) -> CommandWait {
        let semaphore = DispatchSemaphore(value: 0)
        let waiter = Waiter(kind: .command) { _ in semaphore.signal() }
        lock.withLock { enqueue(waiter, path: path) }
        while true {
            let slice = min(
                Self.cancellationPollInterval,
                max(0, deadline.timeIntervalSinceNow)
            )
            if semaphore.wait(timeout: .now() + slice) == .success {
                return lock.withLock {
                    // Turned away early only when terminals fill the master.
                    waiter.granted ? .granted : .terminalsHoldEverySession
                }
            }
            let cancelled = withUnsafeCurrentTask { $0?.isCancelled == true }
            guard cancelled || Date() >= deadline else { continue }
            return lock.withLock {
                if waiter.settled {
                    guard waiter.granted else { return .terminalsHoldEverySession }
                    guard cancelled else { return .granted }
                    // Granted just as the caller gave up: hand it back.
                    releaseCommandLocked(path: path)
                    return .cancelled
                }
                masters[path]?.waiters.removeAll { $0 === waiter }
                waiter.settle(granted: false)
                pruneLocked(path: path)
                return cancelled ? .cancelled : .timedOut
            }
        }
    }

    /// Takes a session for a placed terminal that is about to launch. Waits
    /// ahead of queued commands; returns false when launched terminals
    /// already hold every session, or when the caller is cancelled.
    fileprivate func activateTerminal(path: String) async -> Bool {
        let registration = ActivationRegistration()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    let waiter = Waiter(kind: .terminalActivation) {
                        continuation.resume(returning: $0)
                    }
                    if registration.cancelled {
                        waiter.settle(granted: false)
                        return
                    }
                    registration.waiter = waiter
                    enqueue(waiter, path: path)
                }
            }
        } onCancel: {
            lock.withLock {
                registration.cancelled = true
                guard let waiter = registration.waiter, !waiter.settled else {
                    return
                }
                masters[path]?.waiters.removeAll { $0 === waiter }
                waiter.settle(granted: false)
                pruneLocked(path: path)
            }
        }
    }

    /// Returns a terminal's place, and its session when it launched.
    fileprivate func releaseTerminal(path: String, place: Bool, session: Bool) {
        lock.withLock {
            guard var master = masters[path] else { return }
            if place {
                master.terminals = max(0, master.terminals - 1)
            }
            if session {
                master.activeTerminals = max(0, master.activeTerminals - 1)
                master.open = max(0, master.open - 1)
            }
            masters[path] = master
            grantWaiting(path: path)
            pruneLocked(path: path)
        }
    }

    /// Must be called with `lock` held.
    private func releaseCommandLocked(path: String) {
        guard var master = masters[path] else { return }
        master.open = max(0, master.open - 1)
        masters[path] = master
        grantWaiting(path: path)
        pruneLocked(path: path)
    }

    /// Must be called with `lock` held.
    private func enqueue(_ waiter: Waiter, path: String) {
        var master = masters[path] ?? Master()
        if master.activeTerminals >= master.capacity {
            waiter.settle(granted: false)
            return
        }
        master.waiters.append(waiter)
        masters[path] = master
        grantWaiting(path: path)
    }

    /// Lowers capacity to the sessions Ghosthub had open alongside the
    /// refused one, releases the refused session, and returns that count.
    private func recordRefusal(path: String) -> Int {
        lock.withLock {
            guard var master = masters[path] else { return 0 }
            let othersOpen = max(0, master.open - 1)
            if othersOpen > 0 {
                master.capacity = min(master.capacity, othersOpen)
            }
            master.open = othersOpen
            masters[path] = master
            grantWaiting(path: path)
            return othersOpen
        }
    }

    /// Grants queued sessions while the master has room: terminal launches
    /// first, then commands in arrival order. Requests that can never fit,
    /// because launched terminals hold every session, are turned away.
    /// Must be called with `lock` held.
    private func grantWaiting(path: String) {
        guard var master = masters[path] else { return }
        while master.open < master.capacity, !master.waiters.isEmpty {
            let index = master.waiters.firstIndex {
                $0.kind == .terminalActivation
            } ?? master.waiters.startIndex
            let waiter = master.waiters.remove(at: index)
            master.open += 1
            if waiter.kind == .terminalActivation {
                master.activeTerminals += 1
            }
            waiter.settle(granted: true)
        }
        if master.activeTerminals >= master.capacity {
            for waiter in master.waiters {
                waiter.settle(granted: false)
            }
            master.waiters.removeAll()
        }
        masters[path] = master
    }

    /// Forgets a master with nothing open, placed, queued, or learned.
    /// Must be called with `lock` held.
    private func pruneLocked(path: String) {
        if masters[path]?.isIdle == true {
            masters.removeValue(forKey: path)
        }
    }
}

/// One terminal's place on a master. `activate()` takes its session just
/// before the terminal launches; releasing it, explicitly or by
/// deallocation, returns the place and any session to the budget once.
final class SSHSessionReservation: @unchecked Sendable {
    private let path: String?
    private weak var budget: SSHSessionBudget?
    private let lock = NSLock()
    private var active = false
    private var released = false

    fileprivate init(path: String?, budget: SSHSessionBudget?) {
        self.path = path
        self.budget = budget
    }

    deinit {
        release()
    }

    /// Takes the terminal's session, waiting for a running command to finish
    /// if the master is full. Returns false when the session can't be taken
    /// on this master; activating again after success does nothing.
    func activate() async -> Bool {
        guard let path, let budget else { return true }
        let state = lock.withLock { (active, released) }
        if state.0 {
            return true
        }
        if state.1 {
            return false
        }
        guard await budget.activateTerminal(path: path) else { return false }
        let kept = lock.withLock {
            guard !released else { return false }
            active = true
            return true
        }
        if !kept {
            // Released while waiting; its place is already back.
            budget.releaseTerminal(path: path, place: false, session: true)
        }
        return kept
    }

    func release() {
        let wasActive: Bool? = lock.withLock {
            guard !released else { return nil }
            released = true
            return active
        }
        guard let wasActive, let path else { return }
        budget?.releaseTerminal(path: path, place: true, session: wasActive)
    }
}
