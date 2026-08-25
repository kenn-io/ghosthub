import Foundation

private final class KwtSSHConnectionHandoff: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let cancelAction: @Sendable () async -> Void

    init(
        stream: AsyncStream<Void>,
        cancel: @escaping @Sendable () async -> Void
    ) {
        self.stream = stream
        cancelAction = cancel
    }

    func wait(timeout: Duration) async -> Bool {
        let transferred = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = self.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !transferred {
            await cancelAction()
        }
        return transferred
    }
}

/// One caller's ownership of a pooled kwt SSH lease. Release is idempotent,
/// and an unreleased connection releases itself when it is deallocated.
final class KwtSSHConnection: @unchecked Sendable {
    let arguments: [String]
    let routeIdentity: String
    let generation: UInt64
    let terminalFailure: Task<KwtSSHLeaseError?, Never>

    private let releaseAction: @Sendable () async throws -> Void
    private let invalidateAction: @Sendable () async -> Void
    private let beginHandoffAction:
        @Sendable () async -> KwtSSHConnectionHandoff?
    private let lock = NSLock()
    private var releaseTask: Task<Void, Error>?
    private var released = false

    fileprivate init(
        result: KwtSSHLeaseResult,
        terminalFailure: Task<KwtSSHLeaseError?, Never>,
        pool: KwtSSHConnectionPool,
        routeIdentity: String,
        entryID: UUID,
        token: UUID
    ) {
        arguments = result.arguments
        self.routeIdentity = result.routeIdentity
        generation = result.generation
        self.terminalFailure = terminalFailure
        releaseAction = {
            try await pool.release(entryID: entryID, token: token)
        }
        invalidateAction = {
            await pool.invalidate(
                routeIdentity: routeIdentity,
                generation: result.generation
            )
        }
        beginHandoffAction = {
            await pool.beginHandoff(entryID: entryID, token: token)
        }
    }

    /// A connection whose arguments come from somewhere other than the pool,
    /// such as demo isolation or an injected test transport.
    init(
        arguments: [String],
        routeIdentity: String,
        generation: UInt64,
        terminalFailure: Task<KwtSSHLeaseError?, Never> = Task { nil },
        release: @escaping @Sendable () async throws -> Void = {},
        invalidate: @escaping @Sendable () async -> Void = {}
    ) {
        self.arguments = arguments
        self.routeIdentity = routeIdentity
        self.generation = generation
        self.terminalFailure = terminalFailure
        releaseAction = release
        invalidateAction = invalidate
        beginHandoffAction = { nil }
    }

    deinit {
        let shouldRelease = lock.withLock { !released && releaseTask == nil }
        guard shouldRelease else { return }
        let releaseAction = releaseAction
        Task { try? await releaseAction() }
    }

    func release() async throws {
        let existing: Task<Void, Error>? = lock.withLock {
            if released {
                return nil
            }
            if let releaseTask {
                return releaseTask
            }
            let task = Task { try await releaseAction() }
            releaseTask = task
            return task
        }
        guard let existing else { return }
        do {
            try await existing.value
            lock.withLock {
                released = true
                releaseTask = nil
            }
        } catch {
            lock.withLock { releaseTask = nil }
            throw error
        }
    }

    /// Reports that commands using these arguments can no longer reach the
    /// daemon-owned master. The pool re-leases the route on its next use.
    func invalidate() async {
        await invalidateAction()
    }

    /// Keeps this owner alive until another caller owns the same pooled lease.
    /// The start callback runs only after the transfer is registered.
    @MainActor
    func handoffToNextOwner(
        timeout: Duration = .seconds(5),
        starting start: @MainActor () -> Void
    ) async {
        guard let handoff = await beginHandoffAction() else {
            start()
            try? await release()
            return
        }
        start()
        _ = await handoff.wait(timeout: timeout)
        lock.withLock {
            released = true
            releaseTask = nil
        }
    }
}

/// Shares one kwt lease per route across every concurrent caller in the app.
///
/// The final owner's release returns the lease to kwt, so kwt's own policy
/// decides whether the master stays warm or, for forwarded-agent routes,
/// disconnects at once. Terminal helper failures and reported transport
/// failures mark a shared entry unusable so no new caller joins a dead
/// master; it is released once its last owner lets go.
actor KwtSSHConnectionPool {
    typealias LeaseAcquirer = @Sendable (
        _ route: KwtSSHRouteSnapshot,
        _ prompt: @escaping KwtSSHLeaseClient.PromptHandler
    ) async throws -> any KwtSSHLeaseHolding

    typealias PolicyLeaseAcquirer = @Sendable (
        _ route: KwtSSHRouteSnapshot,
        _ hostKeyPolicy: KwtSSHHostKeyPolicy,
        _ prompt: @escaping KwtSSHLeaseClient.PromptHandler
    ) async throws -> any KwtSSHLeaseHolding

    static let shared = KwtSSHConnectionPool()

    private struct Entry {
        let id: UUID
        let acquisitionID: UUID
        let supersededAcquisitionIDs: Set<UUID>
        let route: KwtSSHRouteSnapshot
        let lease: any KwtSSHLeaseHolding
        var tokens: Set<UUID>
        var handoffs: [UUID: HandoffSignal]
        var cleanup: Cleanup?
        var usable: Bool
        var pendingRelease: Bool
    }

    private struct Acquisition {
        let id: UUID
        let route: KwtSSHRouteSnapshot
        let hostKeyPolicy: KwtSSHHostKeyPolicy
        let task: Task<any KwtSSHLeaseHolding, Error>
        var subscribers: Set<UUID>
        let supersededAcquisitionIDs: Set<UUID>
    }

    private struct Cleanup {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct HandoffSignal {
        let id: UUID
        let continuation: AsyncStream<Void>.Continuation
    }

    private struct PendingClaim {
        let entryID: UUID
        let token: UUID
    }

    private enum PendingClaimResult {
        case none
        case connection(KwtSSHConnection)
        case retry
    }

    private let acquireLease: PolicyLeaseAcquirer
    private var entries: [UUID: Entry] = [:]
    private var currentEntries: [String: UUID] = [:]
    private var acquisitions: [String: Acquisition] = [:]
    private var pendingClaims: [UUID: PendingClaim] = [:]
    private var completedFailures: [UUID: any Error] = [:]
    private var closed = false

    init() {
        acquireLease = { route, hostKeyPolicy, prompt in
            try await KwtSSHLeaseClient().acquire(
                route: route,
                hostKeyPolicy: hostKeyPolicy,
                prompt: prompt
            )
        }
    }

    init(acquireLease: @escaping LeaseAcquirer) {
        self.acquireLease = { route, _, prompt in
            try await acquireLease(route, prompt)
        }
    }

    init(acquireLeaseWithPolicy: @escaping PolicyLeaseAcquirer) {
        acquireLease = acquireLeaseWithPolicy
    }

    func acquire(
        route: KwtSSHRouteSnapshot,
        subscriberID: UUID = UUID(),
        hostKeyPolicy: KwtSSHHostKeyPolicy = .review,
        prompt: @escaping KwtSSHLeaseClient.PromptHandler
    ) async throws -> KwtSSHConnection {
        try await withTaskCancellationHandler {
            try await acquireRegistered(
                route: route,
                subscriberID: subscriberID,
                hostKeyPolicy: hostKeyPolicy,
                prompt: prompt
            )
        } onCancel: { [weak self] in
            Task {
                await self?.cancelAcquisition(
                    routeIdentity: route.routeIdentity,
                    subscriberID: subscriberID
                )
            }
        }
    }

    private func acquireRegistered(
        route: KwtSSHRouteSnapshot,
        subscriberID: UUID,
        hostKeyPolicy: KwtSSHHostKeyPolicy,
        prompt: @escaping KwtSSHLeaseClient.PromptHandler
    ) async throws -> KwtSSHConnection {
        while true {
            try Task.checkCancellation()
            guard !closed else { throw KwtSSHLeaseError.poolClosed }
            if let failure = completedFailures.removeValue(
                forKey: subscriberID
            ) {
                throw failure
            }
            await retryRetiredCleanups(
                routeIdentity: route.routeIdentity
            )
            switch try await consumePendingClaim(
                route: route,
                subscriberID: subscriberID
            ) {
            case .none:
                break
            case let .connection(connection):
                return connection
            case .retry:
                continue
            }
            if let entryID = currentEntries[route.routeIdentity],
               var entry = entries[entryID] {
                guard Self.sameRoute(entry.route, route) else {
                    throw KwtSSHLeaseError.routeChanged
                }
                if let cleanup = entry.cleanup {
                    if let error = await settleCleanup(
                        entryID: entryID,
                        cleanup: cleanup
                    ), !Self.isTerminalReleaseFailure(error) {
                        throw KwtSSHLeaseError.cleanupFailed
                    }
                    continue
                }
                if !entry.usable {
                    if entry.tokens.isEmpty || entry.pendingRelease {
                        try await retryCleanup(entry: entry)
                    } else {
                        currentEntries.removeValue(forKey: route.routeIdentity)
                    }
                    continue
                }
                let token = UUID()
                entry.tokens.insert(token)
                transferHandoffs(in: &entry, to: token)
                entries[entryID] = entry
                return connection(entry: entry, entryID: entryID, token: token)
            }

            let acquisition: Acquisition
            if var existing = acquisitions[route.routeIdentity] {
                guard Self.sameRoute(existing.route, route) else {
                    throw KwtSSHLeaseError.routeChanged
                }
                if existing.hostKeyPolicy == .strict,
                   hostKeyPolicy == .review {
                    existing.task.cancel()
                    existing.subscribers.insert(subscriberID)
                    acquisition = Acquisition(
                        id: UUID(),
                        route: route,
                        hostKeyPolicy: .review,
                        task: Task {
                            try await acquireLease(route, .review, prompt)
                        },
                        subscribers: existing.subscribers,
                        supersededAcquisitionIDs:
                        existing.supersededAcquisitionIDs.union([existing.id])
                    )
                    acquisitions[route.routeIdentity] = acquisition
                } else {
                    existing.subscribers.insert(subscriberID)
                    acquisitions[route.routeIdentity] = existing
                    acquisition = existing
                }
            } else {
                let task = Task {
                    try await acquireLease(route, hostKeyPolicy, prompt)
                }
                acquisition = Acquisition(
                    id: UUID(),
                    route: route,
                    hostKeyPolicy: hostKeyPolicy,
                    task: task,
                    subscribers: [subscriberID],
                    supersededAcquisitionIDs: []
                )
                acquisitions[route.routeIdentity] = acquisition
            }
            do {
                let lease = try await acquisition.task.value
                try Task.checkCancellation()
                switch try await consumePendingClaim(
                    route: route,
                    subscriberID: subscriberID
                ) {
                case .none:
                    break
                case let .connection(connection):
                    return connection
                case .retry:
                    continue
                }
                switch finishAcquisition(
                    routeIdentity: route.routeIdentity,
                    acquisition: acquisition,
                    lease: lease,
                    subscriberID: subscriberID
                ) {
                case let .connection(connection):
                    return connection
                case .joinCurrentEntry:
                    break
                case .releaseLease:
                    try? await lease.release(timeout: .seconds(2))
                }
            } catch {
                if Task.isCancelled {
                    await cancelAcquisition(
                        routeIdentity: route.routeIdentity,
                        subscriberID: subscriberID
                    )
                    throw CancellationError()
                }
                if let failure = completedFailures.removeValue(
                    forKey: subscriberID
                ) {
                    throw failure
                }
                if let current = acquisitions[route.routeIdentity] {
                    if current.supersededAcquisitionIDs.contains(
                        acquisition.id
                    ) {
                        continue
                    }
                    if current.id == acquisition.id {
                        recordFailure(error, for: current)
                    }
                } else if let entryID = currentEntries[route.routeIdentity],
                          let entry = entries[entryID],
                          entry.supersededAcquisitionIDs.contains(
                              acquisition.id
                          ) {
                    continue
                }
                if let failure = completedFailures.removeValue(
                    forKey: subscriberID
                ) {
                    throw failure
                }
                throw error
            }
            continue
        }
    }

    func cancelAcquisition(routeIdentity: String, subscriberID: UUID) async {
        completedFailures.removeValue(forKey: subscriberID)
        if let claim = pendingClaims.removeValue(forKey: subscriberID) {
            try? await release(entryID: claim.entryID, token: claim.token)
        }
        if var acquisition = acquisitions[routeIdentity] {
            acquisition.subscribers.remove(subscriberID)
            if acquisition.subscribers.isEmpty {
                acquisitions.removeValue(forKey: routeIdentity)
                acquisition.task.cancel()
            } else {
                acquisitions[routeIdentity] = acquisition
            }
        }
    }

    /// True while a usable lease for the route has at least one owner.
    func isConnected(routeIdentity: String) -> Bool {
        guard let entryID = currentEntries[routeIdentity],
              let entry = entries[entryID]
        else { return false }
        return entry.usable && entry.cleanup == nil && !entry.tokens.isEmpty
    }

    func releaseAll() async throws {
        closed = true
        let pending = acquisitions
        acquisitions.removeAll()
        var firstError: Error?
        for (routeIdentity, acquisition) in pending {
            acquisition.task.cancel()
            do {
                let lease = try await acquisition.task.value
                do {
                    try await lease.release(timeout: .seconds(2))
                } catch {
                    if !Self.isTerminalReleaseFailure(error) {
                        let entryID = UUID()
                        entries[entryID] = Entry(
                            id: entryID,
                            acquisitionID: acquisition.id,
                            supersededAcquisitionIDs:
                            acquisition.supersededAcquisitionIDs,
                            route: acquisition.route,
                            lease: lease,
                            tokens: [],
                            handoffs: [:],
                            cleanup: nil,
                            usable: false,
                            pendingRelease: false
                        )
                        currentEntries[routeIdentity] = entryID
                    }
                    firstError = firstError ?? error
                }
            } catch is CancellationError {
                continue
            } catch {
                firstError = firstError ?? error
            }
        }

        let entryIDs = entries.values.sorted {
            if $0.route.routeIdentity != $1.route.routeIdentity {
                return $0.route.routeIdentity < $1.route.routeIdentity
            }
            return $0.lease.result.generation < $1.lease.result.generation
        }.map(\.id)
        for entryID in entryIDs {
            guard let entry = entries[entryID] else { continue }
            let cleanup = entry.cleanup ?? beginCleanup(entry: entry)
            if let error = await settleCleanup(
                entryID: entryID,
                cleanup: cleanup
            ) {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    fileprivate func release(entryID: UUID, token: UUID) async throws {
        guard var entry = entries[entryID],
              entry.tokens.contains(token)
        else { return }
        if let cleanup = entry.cleanup {
            try await cleanup.task.value
            return
        }
        if entry.tokens.count > 1 {
            entry.tokens.remove(token)
            entries[entryID] = entry
            return
        }
        entry.pendingRelease = true
        entries[entryID] = entry
        let cleanup = beginCleanup(entry: entry)
        if let error = await settleCleanup(
            entryID: entryID,
            cleanup: cleanup
        ) {
            throw error
        }
    }

    fileprivate func beginHandoff(
        entryID: UUID,
        token: UUID
    ) -> KwtSSHConnectionHandoff? {
        guard var entry = entries[entryID],
              entry.tokens.contains(token),
              entry.cleanup == nil
        else { return nil }
        if entry.tokens.contains(where: { $0 != token }) {
            entry.tokens.remove(token)
            entries[entryID] = entry
            let completed = AsyncStream<Void>.makeStream()
            completed.continuation.yield()
            completed.continuation.finish()
            return KwtSSHConnectionHandoff(
                stream: completed.stream,
                cancel: {}
            )
        }
        let handoffID = UUID()
        let pending = AsyncStream<Void>.makeStream()
        entry.handoffs[token] = HandoffSignal(
            id: handoffID,
            continuation: pending.continuation
        )
        entries[entryID] = entry
        return KwtSSHConnectionHandoff(
            stream: pending.stream,
            cancel: { [weak self] in
                await self?.cancelHandoff(
                    entryID: entryID,
                    token: token,
                    handoffID: handoffID
                )
            }
        )
    }

    private func cancelHandoff(
        entryID: UUID,
        token: UUID,
        handoffID: UUID
    ) async {
        guard var entry = entries[entryID],
              entry.handoffs[token]?.id == handoffID
        else { return }
        entry.handoffs.removeValue(forKey: token)?.continuation.finish()
        entries[entryID] = entry
        try? await release(entryID: entryID, token: token)
    }

    /// Marks the route's current lease unusable so no new caller joins it;
    /// it is released once its last owner lets go.
    func invalidate(routeIdentity: String, generation: UInt64) {
        guard let entryID = currentEntries[routeIdentity],
              let entry = entries[entryID],
              entry.lease.result.generation == generation,
              entry.cleanup == nil
        else { return }
        entries[entryID]?.usable = false
    }

    private enum AcquisitionFinish {
        case connection(KwtSSHConnection)
        case joinCurrentEntry
        case releaseLease
    }

    private func finishAcquisition(
        routeIdentity: String,
        acquisition: Acquisition,
        lease: any KwtSSHLeaseHolding,
        subscriberID: UUID
    ) -> AcquisitionFinish {
        guard let currentAcquisition = acquisitions[routeIdentity],
              currentAcquisition.id == acquisition.id
        else {
            // Another subscriber of this same acquisition may already have
            // installed the shared lease as the current entry; releasing it
            // here would pull the connection out from under its owners.
            if let entryID = currentEntries[routeIdentity],
               entries[entryID]?.acquisitionID == acquisition.id {
                return .joinCurrentEntry
            }
            return .releaseLease
        }
        // A subscriber removed by cancelAcquisition while the shared task
        // kept running can still be the first to observe the lease; it must
        // finish on behalf of the remaining subscribers, never release a
        // lease they are about to claim.
        let token = UUID()
        var claims: [UUID: UUID] = [:]
        for remaining in currentAcquisition.subscribers
            where remaining != subscriberID {
            claims[remaining] = UUID()
        }
        let entryID = UUID()
        acquisitions.removeValue(forKey: routeIdentity)
        for (subscriberID, token) in claims {
            pendingClaims[subscriberID] = PendingClaim(
                entryID: entryID,
                token: token
            )
        }
        let entry = Entry(
            id: entryID,
            acquisitionID: currentAcquisition.id,
            supersededAcquisitionIDs:
            currentAcquisition.supersededAcquisitionIDs,
            route: currentAcquisition.route,
            lease: lease,
            tokens: Set(claims.values).union([token]),
            handoffs: [:],
            cleanup: nil,
            usable: true,
            pendingRelease: false
        )
        entries[entryID] = entry
        currentEntries[routeIdentity] = entryID
        let terminalFailure = lease.terminalFailure
        let generation = lease.result.generation
        Task { [weak self] in
            guard await terminalFailure.value != nil else { return }
            await self?.invalidate(
                routeIdentity: routeIdentity,
                generation: generation
            )
        }
        return .connection(
            connection(entry: entry, entryID: entryID, token: token)
        )
    }

    private func consumePendingClaim(
        route: KwtSSHRouteSnapshot,
        subscriberID: UUID
    ) async throws -> PendingClaimResult {
        guard let claim = pendingClaims.removeValue(forKey: subscriberID)
        else { return .none }
        guard let entry = entries[claim.entryID] else { return .retry }
        guard Self.sameRoute(entry.route, route) else {
            try? await release(entryID: claim.entryID, token: claim.token)
            throw KwtSSHLeaseError.routeChanged
        }
        guard entry.usable, entry.cleanup == nil else {
            try? await release(entryID: claim.entryID, token: claim.token)
            return .retry
        }
        return .connection(connection(
            entry: entry,
            entryID: claim.entryID,
            token: claim.token
        ))
    }

    #if DEBUG
    func hasAcquisitionSubscriber(
        routeIdentity: String,
        subscriberID: UUID
    ) -> Bool {
        acquisitions[routeIdentity]?.subscribers.contains(subscriberID)
            == true
    }
    #endif

    private func connection(
        entry: Entry,
        entryID: UUID,
        token: UUID
    ) -> KwtSSHConnection {
        KwtSSHConnection(
            result: entry.lease.result,
            terminalFailure: entry.lease.terminalFailure,
            pool: self,
            routeIdentity: entry.route.routeIdentity,
            entryID: entryID,
            token: token
        )
    }

    private func recordFailure(_ error: Error, for acquisition: Acquisition) {
        guard acquisitions[acquisition.route.routeIdentity]?.id
            == acquisition.id
        else { return }
        acquisitions.removeValue(forKey: acquisition.route.routeIdentity)
        for subscriberID in acquisition.subscribers {
            completedFailures[subscriberID] = error
        }
    }

    private func transferHandoffs(in entry: inout Entry, to token: UUID) {
        let anchors = entry.handoffs.keys.filter { $0 != token }
        for anchor in anchors {
            entry.tokens.remove(anchor)
            if let signal = entry.handoffs.removeValue(forKey: anchor) {
                signal.continuation.yield()
                signal.continuation.finish()
            }
        }
    }

    private static func sameRoute(
        _ lhs: KwtSSHRouteSnapshot,
        _ rhs: KwtSSHRouteSnapshot
    ) -> Bool {
        lhs.routeIdentity == rhs.routeIdentity
            && lhs.projectionPolicy == rhs.projectionPolicy
            && lhs.logicalTarget == rhs.logicalTarget
            && lhs.targets == rhs.targets
    }

    private static func isTerminalReleaseFailure(_ error: Error) -> Bool {
        guard let error = error as? KwtSSHLeaseError else { return false }
        switch error {
        case .commandFailed, .operationFailed, .malformedEvent:
            return true
        case .helperUnavailable, .launchFailed, .acquisitionTimedOut,
             .persistentUnsupported, .cleanupFailed, .routeChanged,
             .releaseTimedOut, .poolClosed:
            return false
        }
    }

    private func retryCleanup(entry: Entry) async throws {
        let cleanup = beginCleanup(entry: entry)
        if let error = await settleCleanup(
            entryID: entry.id,
            cleanup: cleanup
        ), !Self.isTerminalReleaseFailure(error) {
            throw KwtSSHLeaseError.cleanupFailed
        }
    }

    private func retryRetiredCleanups(routeIdentity: String) async {
        let currentEntryID = currentEntries[routeIdentity]
        let entryIDs = entries.values.filter {
            $0.id != currentEntryID
                && $0.route.routeIdentity == routeIdentity
                && !$0.usable
                && $0.cleanup == nil
                && ($0.tokens.isEmpty || $0.pendingRelease)
        }.sorted {
            $0.lease.result.generation < $1.lease.result.generation
        }.map(\.id)

        for entryID in entryIDs {
            guard let entry = entries[entryID],
                  entryID != currentEntries[routeIdentity],
                  !entry.usable,
                  entry.cleanup == nil,
                  entry.tokens.isEmpty || entry.pendingRelease
            else { continue }
            try? await retryCleanup(entry: entry)
        }
    }

    private func beginCleanup(entry: Entry) -> Cleanup {
        let lease = entry.lease
        let cleanup = Cleanup(
            id: UUID(),
            task: Task {
                try await lease.release(timeout: .seconds(2))
            }
        )
        var current = entry
        current.cleanup = cleanup
        entries[entry.id] = current
        return cleanup
    }

    private func settleCleanup(
        entryID: UUID,
        cleanup: Cleanup
    ) async -> Error? {
        let failure: Error?
        do {
            try await cleanup.task.value
            failure = nil
        } catch {
            failure = error
        }
        guard entries[entryID]?.cleanup?.id == cleanup.id else {
            return failure
        }
        if let failure, !Self.isTerminalReleaseFailure(failure) {
            entries[entryID]?.cleanup = nil
            entries[entryID]?.usable = false
        } else {
            if let entry = entries.removeValue(forKey: entryID),
               currentEntries[entry.route.routeIdentity] == entryID {
                currentEntries.removeValue(forKey: entry.route.routeIdentity)
            }
            pendingClaims = pendingClaims.filter {
                $0.value.entryID != entryID
            }
        }
        return failure
    }
}
