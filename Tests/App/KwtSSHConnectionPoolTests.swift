import Foundation
import Testing
@testable import GhosthubApp

@Suite("kwt SSH connection ownership")
struct KwtSSHConnectionPoolTests {
    @Test("shares one daemon lease until the final connection releases it")
    func sharesLeaseUntilFinalRelease() async throws {
        let releaseCount = LockedValue(0)
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-F", "/private/config", "-S", "/private/socket"],
                releaseCount: releaseCount
            )
        }

        let first = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        let second = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        #expect(acquireCount.load() == 1)
        #expect(first.arguments == [
            "-F", "/private/config", "-S", "/private/socket",
        ])
        #expect(second.arguments == first.arguments)
        try await first.release()
        #expect(releaseCount.load() == 0)
        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity))
        try await second.release()
        #expect(releaseCount.load() == 1)
        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity)
            == false)

        let third = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        #expect(acquireCount.load() == 2)
        try await third.release()
        #expect(releaseCount.load() == 2)
    }

    @MainActor
    @Test("handoff retains the lease until the next owner acquires it")
    func handoffRetainsLeaseUntilNextOwner() async throws {
        let releaseCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                releaseCount: releaseCount
            )
        }
        let anchor = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        var nextOwner: Task<KwtSSHConnection, Error>?

        await anchor.handoffToNextOwner {
            nextOwner = Task {
                try await pool.acquire(
                    route: Self.route,
                    prompt: { _ in "" }
                )
            }
        }
        let task = try #require(nextOwner)
        let connection = try await task.value

        #expect(releaseCount.load() == 0)
        try await connection.release()
        #expect(releaseCount.load() == 1)
    }

    @Test("release is idempotent for one connection")
    func releaseIsIdempotent() async throws {
        let pool = KwtSSHConnectionPool { route, _ in
            KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-S", "/private/socket"]
            )
        }
        let first = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        let second = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        try await first.release()
        try await first.release()

        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity))
        try await second.release()
        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity)
            == false)
    }

    @Test("shares an unchanged route across observation timestamps")
    func sharesAcrossObservationTimestamps() async throws {
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-S", "/private/socket"]
            )
        }
        let newerObservation = KwtSSHRouteSnapshot(
            logicalTarget: Self.route.logicalTarget,
            targets: Self.route.targets,
            routeIdentity: Self.route.routeIdentity,
            projectionPolicy: Self.route.projectionPolicy,
            observedAt: "2026-08-14T12:01:00Z"
        )

        let first = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        let second = try await pool.acquire(
            route: newerObservation,
            prompt: { _ in "" }
        )

        #expect(acquireCount.load() == 1)
        try await first.release()
        try await second.release()
    }

    @Test("refuses snapshots whose execution fields differ")
    func refusesDifferentExecutionSnapshots() async throws {
        let pool = KwtSSHConnectionPool { route, _ in
            KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-S", "/private/socket"]
            )
        }
        let changed = KwtSSHRouteSnapshot(
            logicalTarget: Self.route.logicalTarget,
            targets: [
                KwtSSHResolvedTarget(
                    logicalTarget: KwtSSHTarget(hostname: "build.example.test"),
                    effectiveTarget: KwtSSHTarget(
                        hostname: "203.0.113.22",
                        user: "operator",
                        port: 22
                    ),
                    displayTarget: "operator@build.example.test",
                    hostKeyAlias: nil,
                    strictHostKeyChecking: "yes",
                    projection: KwtSSHExecutionProjection(
                        arguments: ["-F", "/dev/null", "-o", "ForwardAgent=no"]
                    )
                ),
            ],
            routeIdentity: Self.route.routeIdentity,
            projectionPolicy: Self.route.projectionPolicy,
            observedAt: "2026-08-14T12:01:00Z"
        )
        let connection = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        await #expect(throws: KwtSSHLeaseError.routeChanged) {
            _ = try await pool.acquire(route: changed, prompt: { _ in "" })
        }
        try await connection.release()
    }

    @Test("concurrent callers complete one shared acquisition")
    func concurrentCallersCompleteSharedAcquisition() async throws {
        let acquireCount = LockedValue(0)
        let releaseCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(50))
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-S", "/private/socket"],
                releaseCount: releaseCount
            )
        }

        async let first = pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        async let second = pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        let connections = try await [first, second]

        #expect(acquireCount.load() == 1)
        #expect(releaseCount.load() == 0)
        try await connections[0].release()
        #expect(releaseCount.load() == 0)
        try await connections[1].release()
        #expect(releaseCount.load() == 1)
    }

    @Test("shared acquisition reserves every subscriber before returning")
    func sharedAcquisitionReservesEverySubscriber() async throws {
        let acquireCount = LockedValue(0)
        let releaseCount = LockedValue(0)
        let strictStarted = AsyncGate()
        let reviewStarted = AsyncGate()
        let finishAcquisition = AsyncGate()
        let pool = KwtSSHConnectionPool(
            acquireLeaseWithPolicy: { route, policy, _ in
                acquireCount.withLock { $0 += 1 }
                if policy == .strict {
                    strictStarted.open()
                    try await Task.sleep(for: .seconds(30))
                }
                reviewStarted.open()
                await finishAcquisition.wait()
                return KwtSSHTestLease(
                    routeIdentity: route.routeIdentity,
                    releaseCount: releaseCount
                )
            }
        )
        let first = Task(priority: .userInitiated) {
            let connection = try await pool.acquire(
                route: Self.route,
                hostKeyPolicy: .strict,
                prompt: { _ in "" }
            )
            try await connection.release()
        }
        await strictStarted.wait()
        let second = Task(priority: .background) {
            try await pool.acquire(
                route: Self.route,
                hostKeyPolicy: .review,
                prompt: { _ in "" }
            )
        }
        await reviewStarted.wait()
        let lateSubscriberID = UUID()
        let lateSubscriber = Task {
            try await pool.acquire(
                route: Self.route,
                subscriberID: lateSubscriberID,
                hostKeyPolicy: .review,
                prompt: { _ in "" }
            )
        }
        await waitUntil {
            await pool.hasAcquisitionSubscriber(
                routeIdentity: Self.route.routeIdentity,
                subscriberID: lateSubscriberID
            )
        }

        finishAcquisition.open()
        try await first.value
        let connection = try await second.value
        let lateConnection = try await lateSubscriber.value

        #expect(acquireCount.load() == 2)
        #expect(releaseCount.load() == 0)
        try await connection.release()
        #expect(releaseCount.load() == 0)
        try await lateConnection.release()
        #expect(releaseCount.load() == 1)
    }

    @Test("concurrent callers receive one shared acquisition failure")
    func concurrentCallersReceiveSharedFailure() async throws {
        let acquireCount = LockedValue(0)
        let acquisitionStarted = AsyncGate()
        let failAcquisition = AsyncGate()
        let expected = KwtSSHLeaseError.operationFailed(
            code: "ssh_prompt_rejected",
            message: "SSH authentication was canceled.",
            retryable: false
        )
        let pool = KwtSSHConnectionPool { _, _ in
            acquireCount.withLock { $0 += 1 }
            acquisitionStarted.open()
            await failAcquisition.wait()
            throw expected
        }

        let first = Task {
            try await pool.acquire(route: Self.route, prompt: { _ in "" })
        }
        await acquisitionStarted.wait()
        let second = Task {
            try await pool.acquire(route: Self.route, prompt: { _ in "" })
        }
        try await Task.sleep(for: .milliseconds(50))
        failAcquisition.open()

        for result in await [first.result, second.result] {
            switch result {
            case .success:
                Issue.record("shared acquisition unexpectedly succeeded")
            case let .failure(error):
                #expect(error as? KwtSSHLeaseError == expected)
            }
        }
        #expect(acquireCount.load() == 1)
    }

    @Test("shared failure is not replaced by an independent retry")
    func sharedFailureIsNotReplacedByIndependentRetry() async throws {
        let policies = LockedValue<[KwtSSHHostKeyPolicy]>([])
        let strictStarted = AsyncGate()
        let reviewStarted = AsyncGate()
        let failReview = AsyncGate()
        let firstFailure = KwtSSHLeaseError.operationFailed(
            code: "ssh_prompt_rejected",
            message: "First attempt failed.",
            retryable: false
        )
        let pool = KwtSSHConnectionPool(
            acquireLeaseWithPolicy: { route, policy, _ in
                policies.withLock { $0.append(policy) }
                if policy == .strict {
                    strictStarted.open()
                    try await Task.sleep(for: .seconds(30))
                }
                if policies.load().count == 2 {
                    reviewStarted.open()
                    await failReview.wait()
                    throw firstFailure
                }
                return KwtSSHTestLease(routeIdentity: route.routeIdentity)
            }
        )
        let first = Task {
            try await pool.acquire(
                route: Self.route,
                hostKeyPolicy: .strict,
                prompt: { _ in "" }
            )
        }
        await strictStarted.wait()
        let originalWaiter = Task {
            try await pool.acquire(
                route: Self.route,
                hostKeyPolicy: .review,
                prompt: { _ in "" }
            )
        }
        await reviewStarted.wait()
        failReview.open()

        _ = await first.result
        let retry = Task {
            try await pool.acquire(
                route: Self.route,
                hostKeyPolicy: .review,
                prompt: { _ in "" }
            )
        }

        switch await originalWaiter.result {
        case .success:
            Issue.record("original waiter silently joined the retry")
        case let .failure(error):
            #expect(error as? KwtSSHLeaseError == firstFailure)
        }
        let retriedConnection = try await retry.value
        #expect(policies.load() == [.strict, .review, .review])
        try await retriedConnection.release()
    }

    @Test("a review-capable caller promotes a shared strict acquisition")
    func promotesStrictAcquisitionForInteractiveReview() async throws {
        let strictStarted = AsyncGate()
        let policies = LockedValue<[KwtSSHHostKeyPolicy]>([])
        let pool = KwtSSHConnectionPool(
            acquireLeaseWithPolicy: { route, policy, _ in
                policies.withLock { $0.append(policy) }
                if policy == .strict {
                    strictStarted.open()
                    try await Task.sleep(for: .seconds(30))
                }
                return KwtSSHTestLease(
                    routeIdentity: route.routeIdentity,
                    arguments: ["-S", "/private/socket"]
                )
            }
        )
        let strict = Task {
            try await pool.acquire(
                route: Self.route,
                hostKeyPolicy: .strict,
                prompt: { _ in "" }
            )
        }
        await strictStarted.wait()
        let review = Task {
            try await pool.acquire(
                route: Self.route,
                hostKeyPolicy: .review,
                prompt: { _ in "approved" }
            )
        }

        let connections = try await [strict.value, review.value]

        #expect(policies.load() == [.strict, .review])
        try await connections[0].release()
        try await connections[1].release()
    }

    @Test("an invalidated shared lease is not joined and is replaced")
    func invalidationReplacesLease() async throws {
        let releaseCount = LockedValue(0)
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            let generation = UInt64(acquireCount.load())
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: generation,
                arguments: ["-S", "/private/socket-\(generation)"],
                releaseCount: releaseCount
            )
        }
        let owner = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        await owner.invalidate()
        #expect(releaseCount.load() == 0)

        let replacement = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        #expect(replacement.generation == 2)
        #expect(replacement.arguments == ["-S", "/private/socket-2"])
        #expect(releaseCount.load() == 0)
        try await owner.release()
        #expect(releaseCount.load() == 1)
        try await replacement.release()
        #expect(releaseCount.load() == 2)
    }

    @Test("invalidation from a stale generation is ignored")
    func ignoresStaleInvalidation() async throws {
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            let generation = UInt64(acquireCount.load())
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: generation,
                arguments: ["-S", "/private/socket-\(generation)"]
            )
        }
        let first = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        try await first.release()
        let replacement = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        await first.invalidate()

        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity))
        #expect(replacement.generation == 2)
        try await replacement.release()
    }

    @Test("retries the final cleanup when kwt reports a release failure")
    func retriesFailedFinalRelease() async throws {
        let attempts = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-S", "/private/socket"],
                onRelease: {
                    attempts.withLock { $0 += 1 }
                    if attempts.load() == 1 {
                        throw KwtSSHLeaseError.releaseTimedOut
                    }
                }
            )
        }
        let connection = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        await #expect(throws: KwtSSHLeaseError.releaseTimedOut) {
            try await connection.release()
        }
        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity)
            == false)
        let replacement = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        #expect(attempts.load() == 2)
        try await replacement.release()
        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity)
            == false)
    }

    @Test("a route acquisition retries retired lease cleanup")
    func retriesRetiredLeaseCleanupAfterReplacement() async throws {
        let acquireCount = LockedValue(0)
        let retiredReleaseAttempts = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            let generation = UInt64(acquireCount.load())
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: generation,
                arguments: ["-S", "/private/socket-\(generation)"],
                onRelease: {
                    guard generation == 1 else { return }
                    retiredReleaseAttempts.withLock { $0 += 1 }
                    if retiredReleaseAttempts.load() == 1 {
                        throw KwtSSHLeaseError.releaseTimedOut
                    }
                }
            )
        }
        let retired = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        await retired.invalidate()
        let current = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        await #expect(throws: KwtSSHLeaseError.releaseTimedOut) {
            try await retired.release()
        }
        #expect(retiredReleaseAttempts.load() == 1)
        let joinedCurrent = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        #expect(joinedCurrent.generation == 2)
        #expect(retiredReleaseAttempts.load() == 2)
        try await joinedCurrent.release()
        try await current.release()
    }

    @Test("one subscriber can leave a shared acquisition")
    func cancelsOnlyFinalAcquisitionSubscriber() async {
        let canceled = AsyncStream<Void>.makeStream()
        let blocker = AsyncStream<Void>.makeStream()
        let pool = KwtSSHConnectionPool { route, _ in
            do {
                var iterator = blocker.stream.makeAsyncIterator()
                _ = await iterator.next()
                try Task.checkCancellation()
                return KwtSSHTestLease(
                    routeIdentity: route.routeIdentity,
                    arguments: ["-S", "/private/socket"]
                )
            } catch {
                canceled.continuation.yield()
                throw error
            }
        }
        let firstID = UUID()
        let secondID = UUID()
        let first = Task {
            try await pool.acquire(
                route: Self.route,
                subscriberID: firstID,
                prompt: { _ in "" }
            )
        }
        let second = Task {
            try await pool.acquire(
                route: Self.route,
                subscriberID: secondID,
                prompt: { _ in "" }
            )
        }
        try? await Task.sleep(for: .milliseconds(30))

        await pool.cancelAcquisition(
            routeIdentity: Self.route.routeIdentity,
            subscriberID: firstID
        )
        #expect(first.isCancelled == false)
        await pool.cancelAcquisition(
            routeIdentity: Self.route.routeIdentity,
            subscriberID: secondID
        )
        blocker.continuation.finish()
        var cancellation = canceled.stream.makeAsyncIterator()
        _ = await cancellation.next()

        first.cancel()
        second.cancel()
        _ = await first.result
        _ = await second.result
    }

    @Test("a removed subscriber never releases the survivors' shared lease")
    func removedSubscriberDoesNotReleaseSharedLease() async throws {
        let releaseCount = LockedValue(0)
        let blocker = AsyncStream<Void>.makeStream()
        let pool = KwtSSHConnectionPool { route, _ in
            var iterator = blocker.stream.makeAsyncIterator()
            _ = await iterator.next()
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                releaseCount: releaseCount
            )
        }
        let survivorID = UUID()
        let removedID = UUID()
        let survivor = Task {
            try await pool.acquire(
                route: Self.route,
                subscriberID: survivorID,
                prompt: { _ in "" }
            )
        }
        let removed = Task {
            try await pool.acquire(
                route: Self.route,
                subscriberID: removedID,
                prompt: { _ in "" }
            )
        }
        try? await Task.sleep(for: .milliseconds(30))

        // The coordinator's prompt-failure path removes a subscriber
        // without cancelling its Swift task; the removed task still
        // observes the shared lease when acquisition completes.
        await pool.cancelAcquisition(
            routeIdentity: Self.route.routeIdentity,
            subscriberID: removedID
        )
        blocker.continuation.finish()

        let survivorConnection = try await survivor.value
        let removedConnection = try await removed.value
        #expect(releaseCount.load() == 0)
        try await removedConnection.release()
        #expect(releaseCount.load() == 0)
        try await survivorConnection.release()
        #expect(releaseCount.load() == 1)
        #expect(await pool.isConnected(
            routeIdentity: Self.route.routeIdentity
        ) == false)
    }

    @Test("a terminal helper failure invalidates only its generation")
    func invalidatesTerminalGeneration() async throws {
        let failure = AsyncStream<KwtSSHLeaseError?>.makeStream()
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            let generation = UInt64(acquireCount.load())
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: generation,
                arguments: ["-S", "/private/socket-\(generation)"],
                terminalFailure: generation == 1
                    ? Task {
                        var iterator = failure.stream.makeAsyncIterator()
                        return await iterator.next() ?? nil
                    }
                    : Task { nil }
            )
        }
        let first = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        failure.continuation.yield(.operationFailed(
            code: "ssh_connection_changed",
            message: "SSH connection changed.",
            retryable: false
        ))
        failure.continuation.finish()
        await waitUntil(timeout: .seconds(1)) {
            await pool.isConnected(
                routeIdentity: Self.route.routeIdentity
            ) == false
        }
        let replacement = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        #expect(replacement.generation == 2)
        try await first.release()
        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity))
        try await replacement.release()
    }

    @Test("a structured terminal failure permits replacement acquisition")
    func replacesStructuredTerminalFailure() async throws {
        let failure = KwtSSHLeaseError.operationFailed(
            code: "ssh_connection_changed",
            message: "SSH connection changed.",
            retryable: false
        )
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            let attempt = acquireCount.load()
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: UInt64(attempt),
                arguments: ["-S", "/private/socket-\(attempt)"],
                terminalFailure: Task { attempt == 1 ? failure : nil },
                onRelease: {
                    if attempt == 1 {
                        throw failure
                    }
                }
            )
        }
        let first = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        await waitUntil(timeout: .seconds(1)) {
            await pool.isConnected(
                routeIdentity: Self.route.routeIdentity
            ) == false
        }

        let replacement = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        #expect(replacement.generation == 2)
        await #expect(throws: KwtSSHLeaseError.self) {
            try await first.release()
        }
        try await replacement.release()
    }

    @Test("a dead helper is evicted instead of retried")
    func evictsTerminalReleaseFailure() async throws {
        let attempts = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-S", "/private/socket"],
                onRelease: {
                    attempts.withLock { $0 += 1 }
                    throw KwtSSHLeaseError.commandFailed(status: 17)
                }
            )
        }
        let connection = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        await #expect(throws: KwtSSHLeaseError.commandFailed(status: 17)) {
            try await connection.release()
        }
        try await connection.release()
        #expect(attempts.load() == 1)
        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity)
            == false)
    }

    @Test("terminal cleanup failure does not block replacement acquisition")
    func terminalCleanupFailureAllowsReplacement() async throws {
        let acquireCount = LockedValue(0)
        let cleanupStarted = AsyncGate()
        let finishCleanup = AsyncGate()
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            let attempt = acquireCount.load()
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: UInt64(attempt),
                onRelease: {
                    guard attempt == 1 else { return }
                    cleanupStarted.open()
                    await finishCleanup.wait()
                    throw KwtSSHLeaseError.commandFailed(status: 17)
                }
            )
        }
        let first = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        let release = Task { try await first.release() }
        await cleanupStarted.wait()
        let replacement = Task {
            try await pool.acquire(route: Self.route, prompt: { _ in "" })
        }

        finishCleanup.open()
        await #expect(throws: KwtSSHLeaseError.commandFailed(status: 17)) {
            try await release.value
        }
        let connection = try await replacement.value

        #expect(connection.generation == 2)
        try await connection.release()
    }

    @Test("shutdown releases retained connections and refuses new ownership")
    func releasesAllForShutdown() async throws {
        let releaseCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                arguments: ["-S", "/private/socket"],
                releaseCount: releaseCount
            )
        }
        let owned = try await pool.acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        try await pool.releaseAll()

        #expect(releaseCount.load() == 1)
        #expect(await pool.isConnected(routeIdentity: Self.route.routeIdentity)
            == false)
        await #expect(throws: KwtSSHLeaseError.poolClosed) {
            _ = try await pool.acquire(
                route: Self.route,
                prompt: { _ in "" }
            )
        }
        try await owned.release()
    }

    private static let route = KwtSSHRouteSnapshot.fixture(
        observedAt: "2026-08-14T12:00:00Z"
    )
}
