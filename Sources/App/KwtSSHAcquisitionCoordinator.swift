import Foundation
import GhosthubTransport

struct KwtSSHDestinationRequest: Hashable, Sendable {
    let destination: String
    let host: SSHHostInfo

    init(destination: String, host: SSHHostInfo) {
        self.destination = destination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.host = host
    }
}

/// Shares SSH acquisition across windows in two stages: one kwt route
/// resolution per destination, then one pooled lease per route identity.
/// Commands use the route's primary master; each terminal reserves a place
/// on the first master whose session budget has room for it, and a command
/// turned away by a full master runs on another master of the same route.
///
/// Every new ownership boundary resolves again, so a configuration change
/// surfaces as `ssh_configuration_changed` before a caller joins a route;
/// only concurrent resolutions of one destination are coalesced.
actor KwtSSHAcquisitionCoordinator {
    typealias Resolver = @Sendable (KwtSSHDestinationRequest) async throws
        -> KwtSSHRouteSnapshot
    typealias PromptHandler = @Sendable (
        _ route: KwtSSHRouteSnapshot,
        _ prompt: KwtSSHLeasePrompt
    ) async throws -> String

    static let shared = KwtSSHAcquisitionCoordinator()

    private struct Resolution {
        let id: UUID
        let task: Task<KwtSSHRouteSnapshot, Error>
        var subscribers: Set<UUID>
    }

    private struct Subscriber {
        let request: KwtSSHDestinationRequest
        let canPresentPrompts: Bool
        let prompt: PromptHandler
        let order: UInt64
        var routeIdentity: String?
        /// The master this subscriber is waiting on. Each master
        /// authenticates on its own, so only its waiters see its prompts.
        var lane: Int?
    }

    private struct LaneKey: Hashable {
        let routeIdentity: String
        let lane: Int
    }

    private let resolve: Resolver
    private let lanes: KwtSSHConnectionLanes
    private let budget: SSHSessionBudget
    private var resolutions: [KwtSSHDestinationRequest: Resolution] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var browserPrompts: [LaneKey: KwtSSHLeasePrompt] = [:]
    private var nextOrder: UInt64 = 0
    /// Routes with a prompt on screen, and lease operations waiting to show
    /// theirs. Masters of one route authenticate separately, so their
    /// prompts take turns instead of reaching one window at once.
    private var promptingRoutes: Set<String> = []
    private var promptQueues: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        resolve: @escaping Resolver = { request in
            try await BlockingTask.runThrowing(priority: .userInitiated) {
                try KwtSSHRouteClient().resolve(request.host)
            }
        },
        pool: KwtSSHConnectionPool = .shared,
        lanes: KwtSSHConnectionLanes? = nil,
        budget: SSHSessionBudget = .shared
    ) {
        self.resolve = resolve
        self.lanes = lanes ?? (pool === KwtSSHConnectionPool.shared
            ? .shared
            : KwtSSHConnectionLanes(primary: pool))
        self.budget = budget
    }

    func acquire(
        request: KwtSSHDestinationRequest,
        subscriberID: UUID,
        canPresentPrompts: Bool,
        purpose: KwtSSHConnectionPurpose = .commands,
        prompt: @escaping PromptHandler
    ) async throws -> KwtSSHConnection {
        nextOrder &+= 1
        subscribers[subscriberID] = Subscriber(
            request: request,
            canPresentPrompts: canPresentPrompts,
            prompt: prompt,
            order: nextOrder,
            routeIdentity: nil
        )

        return try await withTaskCancellationHandler {
            do {
                let route = try await resolvedRoute(
                    request: request,
                    subscriberID: subscriberID
                )
                guard subscribers[subscriberID] != nil else {
                    throw CancellationError()
                }
                let connection = try await acquirePlaced(
                    purpose: purpose,
                    route: route,
                    subscriberID: subscriberID,
                    canPresentPrompts: canPresentPrompts
                )
                subscribers.removeValue(forKey: subscriberID)
                registerOverflow(for: connection, request: request)
                return connection
            } catch {
                await cancel(
                    request: request,
                    subscriberID: subscriberID
                )
                throw error
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancel(
                    request: request,
                    subscriberID: subscriberID
                )
            }
        }
    }

    func cancel(
        request: KwtSSHDestinationRequest,
        subscriberID: UUID
    ) async {
        let routeIdentity = subscribers.removeValue(
            forKey: subscriberID
        )?.routeIdentity
        if var resolution = resolutions[request] {
            resolution.subscribers.remove(subscriberID)
            if resolution.subscribers.isEmpty {
                resolutions.removeValue(forKey: request)
                resolution.task.cancel()
            } else {
                resolutions[request] = resolution
            }
        }
        if let routeIdentity {
            // Drop sign-in notices for masters nobody waits on any more.
            browserPrompts = browserPrompts.filter { key, _ in
                key.routeIdentity != routeIdentity
                    || subscribers.values.contains {
                        $0.routeIdentity == routeIdentity && $0.lane == key.lane
                    }
            }
            for pool in lanes.activePools {
                await pool.cancelAcquisition(
                    routeIdentity: routeIdentity,
                    subscriberID: subscriberID
                )
            }
        }
    }

    /// Uses the first master with room for the purpose, leasing the next
    /// master when every earlier one is full. Commands normally stay on the
    /// primary master; they move only when terminals hold every session it
    /// allows. A terminal reserves its session for its whole lifetime. A new
    /// master authenticates on its own, so it may prompt like the first one.
    private func acquirePlaced(
        purpose: KwtSSHConnectionPurpose,
        route: KwtSSHRouteSnapshot,
        subscriberID: UUID,
        canPresentPrompts: Bool
    ) async throws -> KwtSSHConnection {
        let hostKeyPolicy: KwtSSHHostKeyPolicy =
            canPresentPrompts ? .review : .strict
        for index in 0 ..< KwtSSHConnectionLanes.maximumLanes {
            let key = LaneKey(routeIdentity: route.routeIdentity, lane: index)
            subscribers[subscriberID]?.lane = index
            if canPresentPrompts, let notice = browserPrompts[key],
               let subscriber = subscribers[subscriberID] {
                _ = try await subscriber.prompt(route, notice)
            }
            let connection = try await lanes.pool(index).acquire(
                route: route,
                subscriberID: subscriberID,
                hostKeyPolicy: hostKeyPolicy,
                prompt: { [weak self] leasePrompt in
                    guard let self else { throw CancellationError() }
                    return try await answerPrompt(
                        route: route,
                        lane: index,
                        prompt: leasePrompt
                    )
                }
            )
            // This master is connected, so its sign-in notice is done.
            browserPrompts.removeValue(forKey: key)
            switch purpose {
            case .commands:
                if budget.hasCommandRoom(arguments: connection.arguments) {
                    return connection
                }
            case .terminal:
                if let reservation = budget.reserveTerminal(
                    arguments: connection.arguments
                ) {
                    connection.holdSessionReservation(reservation)
                    return connection
                }
            }
            try? await connection.release()
            try Task.checkCancellation()
        }
        throw KwtSSHLeaseError.operationFailed(
            code: "ssh_session_capacity",
            message: "Every SSH connection to this host is full. "
                + "Close a session and try again.",
            retryable: true
        )
    }

    /// Lets commands stranded on this connection's master, because terminals
    /// hold every session there, run on another master of the same route.
    /// The replacement is leased without prompts and must keep the route
    /// identity.
    private nonisolated func registerOverflow(
        for connection: KwtSSHConnection,
        request: KwtSSHDestinationRequest
    ) {
        let routeIdentity = connection.routeIdentity
        let budget = budget
        budget.registerOverflow(arguments: connection.arguments) {
            [weak self] deadline in
            guard let self else { return nil }
            return KwtSSHOverflowWait.lease(until: deadline) {
                let replacement = try await self.acquire(
                    request: request,
                    subscriberID: UUID(),
                    canPresentPrompts: false,
                    prompt: { _, _ in
                        throw KwtSSHLeaseError.operationFailed(
                            code: "ssh_interaction_required",
                            message: "SSH authentication requires an active window.",
                            retryable: false
                        )
                    }
                )
                guard replacement.routeIdentity == routeIdentity,
                      budget.hasCommandRoom(arguments: replacement.arguments)
                else {
                    try? await replacement.release()
                    return nil
                }
                return replacement
            }
        }
    }

    private func resolvedRoute(
        request: KwtSSHDestinationRequest,
        subscriberID: UUID
    ) async throws -> KwtSSHRouteSnapshot {
        let resolution: Resolution
        if var existing = resolutions[request] {
            existing.subscribers.insert(subscriberID)
            resolutions[request] = existing
            resolution = existing
        } else {
            let id = UUID()
            let task = Task { try await resolve(request) }
            resolution = Resolution(
                id: id,
                task: task,
                subscribers: [subscriberID]
            )
            resolutions[request] = resolution
        }
        defer { finishResolution(request: request, id: resolution.id) }
        let route = try await resolution.task.value
        if let current = resolutions[request], current.id == resolution.id {
            for subscriberID in current.subscribers {
                subscribers[subscriberID]?.routeIdentity = route.routeIdentity
            }
        }
        return route
    }

    private func finishResolution(
        request: KwtSSHDestinationRequest,
        id: UUID
    ) {
        guard resolutions[request]?.id == id else { return }
        resolutions.removeValue(forKey: request)
    }

    private func answerPrompt(
        route: KwtSSHRouteSnapshot,
        lane: Int,
        prompt: KwtSSHLeasePrompt
    ) async throws -> String {
        await beginPrompt(routeIdentity: route.routeIdentity)
        defer { endPrompt(routeIdentity: route.routeIdentity) }
        try Task.checkCancellation()
        return try await presentPrompt(route: route, lane: lane, prompt: prompt)
    }

    private func beginPrompt(routeIdentity: String) async {
        guard promptingRoutes.contains(routeIdentity) else {
            promptingRoutes.insert(routeIdentity)
            return
        }
        await withCheckedContinuation { continuation in
            promptQueues[routeIdentity, default: []].append(continuation)
        }
    }

    private func endPrompt(routeIdentity: String) {
        guard var queue = promptQueues[routeIdentity], !queue.isEmpty else {
            promptQueues.removeValue(forKey: routeIdentity)
            promptingRoutes.remove(routeIdentity)
            return
        }
        let next = queue.removeFirst()
        promptQueues[routeIdentity] = queue.isEmpty ? nil : queue
        next.resume()
    }

    /// Shows a master's prompt in the oldest window waiting on that master.
    private func presentPrompt(
        route: KwtSSHRouteSnapshot,
        lane: Int,
        prompt: KwtSSHLeasePrompt
    ) async throws -> String {
        if prompt.kind == .browserAuthentication {
            browserPrompts[
                LaneKey(routeIdentity: route.routeIdentity, lane: lane)
            ] = prompt
        }
        func waits(_ subscriber: Subscriber?) -> Bool {
            subscriber?.routeIdentity == route.routeIdentity
                && subscriber?.lane == lane
        }
        var deliveredBrowserPrompt = false
        var attempted: Set<UUID> = []
        while true {
            guard let candidate = subscribers
                .filter({ id, subscriber in
                    !attempted.contains(id)
                        && subscriber.canPresentPrompts
                        && waits(subscriber)
                })
                .min(by: { $0.value.order < $1.value.order })
            else {
                if deliveredBrowserPrompt {
                    return ""
                }
                throw KwtSSHLeaseError.operationFailed(
                    code: "ssh_interaction_required",
                    message: "SSH authentication requires an active window.",
                    retryable: false
                )
            }
            attempted.insert(candidate.key)
            do {
                let response = try await candidate.value.prompt(route, prompt)
                guard waits(subscribers[candidate.key]) else { continue }
                if prompt.kind == .browserAuthentication {
                    deliveredBrowserPrompt = true
                } else {
                    return response
                }
            } catch let error as KwtSSHLeaseError
                where error.code == "ssh_prompt_timed_out" {
                throw error
            } catch {
                await cancel(
                    request: candidate.value.request,
                    subscriberID: candidate.key
                )
            }
        }
    }
}

/// Bridges an async lease into a blocking command thread for the session
/// budget. A lease that arrives after the caller stopped waiting is released.
enum KwtSSHOverflowWait {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var connection: KwtSSHConnection?
        var finished = false
        var abandoned = false
    }

    static func lease(
        until deadline: Date,
        _ acquire: @escaping @Sendable () async throws -> KwtSSHConnection?
    ) -> SSHSessionBudget.Overflow? {
        let state = State()
        let done = DispatchSemaphore(value: 0)
        let task = Task {
            let connection = try? await acquire()
            let kept = state.lock.withLock {
                guard !state.abandoned else { return false }
                state.connection = connection
                state.finished = true
                return true
            }
            if !kept {
                try? await connection?.release()
            }
            done.signal()
        }
        while done.wait(timeout: .now() + SSHSessionBudget.cancellationPollInterval)
            == .timedOut {
            let cancelled = withUnsafeCurrentTask { $0?.isCancelled == true }
            guard cancelled || Date() >= deadline else { continue }
            let finished = state.lock.withLock {
                state.abandoned = !state.finished
                return state.finished
            }
            if !finished {
                task.cancel()
                return nil
            }
            break
        }
        guard let connection = state.lock.withLock({ state.connection }) else {
            return nil
        }
        return SSHSessionBudget.Overflow(
            arguments: connection.arguments,
            release: { Task { try? await connection.release() } }
        )
    }
}
