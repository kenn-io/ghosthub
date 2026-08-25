import Foundation
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("kwt SSH acquisition coordination")
struct KwtSSHAcquisitionCoordinatorTests {
    @Test("same destinations share resolution and acquisition")
    func sharesResolutionAndAcquisition() async throws {
        let resolveCount = LockedValue(0)
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(30))
            return KwtSSHTestLease(routeIdentity: route.routeIdentity)
        }
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in
                resolveCount.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(30))
                return Self.route
            },
            pool: pool
        )

        async let first = coordinator.acquire(
            request: Self.request,
            subscriberID: UUID(),
            canPresentPrompts: true,
            prompt: { _, _ in "" }
        )
        async let second = coordinator.acquire(
            request: Self.request,
            subscriberID: UUID(),
            canPresentPrompts: true,
            prompt: { _, _ in "" }
        )
        let connections = try await [first, second]

        #expect(resolveCount.load() == 1)
        #expect(acquireCount.load() == 1)
        try await connections[0].release()
        try await connections[1].release()
    }

    @Test("each new owner resolves again after the route was released")
    func resolvesAtEveryOwnershipBoundary() async throws {
        let resolveCount = LockedValue(0)
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            return KwtSSHTestLease(routeIdentity: route.routeIdentity)
        }
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in
                resolveCount.withLock { $0 += 1 }
                return Self.route
            },
            pool: pool
        )

        let first = try await coordinator.acquire(
            request: Self.request,
            subscriberID: UUID(),
            canPresentPrompts: false,
            prompt: { _, _ in "" }
        )
        try await first.release()
        let second = try await coordinator.acquire(
            request: Self.request,
            subscriberID: UUID(),
            canPresentPrompts: false,
            prompt: { _, _ in "" }
        )
        try await second.release()

        #expect(resolveCount.load() == 2)
        #expect(acquireCount.load() == 2)
    }

    @Test("a response from a presenter that left is not submitted")
    func discardsResponseFromRemovedPresenter() async throws {
        let responses = LockedValue<[String]>([])
        let resolveCount = LockedValue(0)
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstAnswer = AsyncStream<Void>.makeStream()
        let pool = KwtSSHConnectionPool { route, prompt in
            let response = try await prompt(Self.prompt)
            try Task.checkCancellation()
            responses.withLock { $0.append(response) }
            return KwtSSHTestLease(routeIdentity: route.routeIdentity)
        }
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in
                resolveCount.withLock { $0 += 1 }
                return Self.route
            },
            pool: pool
        )
        let firstID = UUID()
        let first = Task {
            try await coordinator.acquire(
                request: Self.request,
                subscriberID: firstID,
                canPresentPrompts: true,
                prompt: { _, _ in
                    firstStarted.continuation.yield()
                    var iterator = firstAnswer.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    return "stale-window"
                }
            )
        }
        var started = firstStarted.stream.makeAsyncIterator()
        _ = await started.next()
        let second = Task {
            try await coordinator.acquire(
                request: Self.request,
                subscriberID: UUID(),
                canPresentPrompts: true,
                prompt: { _, _ in "current-window" }
            )
        }
        await waitUntil { resolveCount.load() == 2 }

        await coordinator.cancel(request: Self.request, subscriberID: firstID)
        firstAnswer.continuation.finish()
        let secondConnection = try await second.value

        #expect(responses.load() == ["current-window"])
        try await secondConnection.release()
        first.cancel()
        _ = await first.result
    }

    @Test("prompt ownership transfers without changing prompt identity")
    func transfersPromptOwnership() async throws {
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstCanceled = AsyncStream<Void>.makeStream()
        let firstResponse = AsyncStream<String>.makeStream()
        let seen = LockedValue<[String]>([])
        let resolveCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, prompt in
            let response = try await prompt(Self.prompt)
            seen.withLock { $0.append(response) }
            return KwtSSHTestLease(routeIdentity: route.routeIdentity)
        }
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in
                resolveCount.withLock { $0 += 1 }
                return Self.route
            },
            pool: pool
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = Task {
            try await coordinator.acquire(
                request: Self.request,
                subscriberID: firstID,
                canPresentPrompts: true,
                prompt: { _, _ in
                    firstStarted.continuation.yield()
                    var iterator = firstResponse.stream.makeAsyncIterator()
                    guard let response = await iterator.next() else {
                        firstCanceled.continuation.yield()
                        throw CancellationError()
                    }
                    return response
                }
            )
        }
        var started = firstStarted.stream.makeAsyncIterator()
        _ = await started.next()
        let second = Task {
            try await coordinator.acquire(
                request: Self.request,
                subscriberID: secondID,
                canPresentPrompts: true,
                prompt: { _, prompt in
                    #expect(prompt.id == Self.prompt.id)
                    #expect(prompt.deadline == Self.prompt.deadline)
                    return "second-window"
                }
            )
        }
        await waitUntil { resolveCount.load() == 2 }

        firstResponse.continuation.finish()
        var canceled = firstCanceled.stream.makeAsyncIterator()
        _ = await canceled.next()
        let secondConnection = try await second.value
        let firstConnection = try await first.value

        #expect(seen.load() == ["second-window"])
        try await firstConnection.release()
        try await secondConnection.release()
    }

    @Test("a prompt with no presenter fails immediately")
    func failsWithoutPromptPresenter() async {
        let pool = KwtSSHConnectionPool { _, prompt in
            _ = try await prompt(Self.prompt)
            Issue.record("prompt unexpectedly received a response")
            return KwtSSHTestLease(routeIdentity: Self.route.routeIdentity)
        }
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in Self.route },
            pool: pool
        )

        do {
            _ = try await coordinator.acquire(
                request: Self.request,
                subscriberID: UUID(),
                canPresentPrompts: false,
                prompt: { _, _ in "" }
            )
            Issue.record("expected interaction-required failure")
        } catch let error as KwtSSHLeaseError {
            #expect(error.code == "ssh_interaction_required")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(
        "host-key policy follows prompt capability",
        arguments: [
            (canPresent: true, expected: KwtSSHHostKeyPolicy.review),
            (canPresent: false, expected: KwtSSHHostKeyPolicy.strict),
        ]
    )
    func selectsHostKeyPolicy(
        canPresent: Bool,
        expected: KwtSSHHostKeyPolicy
    ) async throws {
        let observed = LockedValue<KwtSSHHostKeyPolicy?>(nil)
        let pool = KwtSSHConnectionPool(acquireLeaseWithPolicy: { route, policy, _ in
            observed.withLock { $0 = policy }
            return KwtSSHTestLease(routeIdentity: route.routeIdentity)
        })
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in Self.route },
            pool: pool
        )

        let connection = try await coordinator.acquire(
            request: Self.request,
            subscriberID: UUID(),
            canPresentPrompts: canPresent,
            prompt: { _, _ in "" }
        )

        #expect(observed.load() == expected)
        try await connection.release()
    }

    private static let request = KwtSSHDestinationRequest(
        destination: "build.example.test",
        host: SSHHostInfo(
            user: nil,
            hostname: "build.example.test",
            port: nil
        )
    )

    private static let route = KwtSSHRouteSnapshot.fixture(
        targets: [
            KwtSSHResolvedTarget(
                logicalTarget: KwtSSHTarget(hostname: "build.example.test"),
                effectiveTarget: KwtSSHTarget(hostname: "192.0.2.20"),
                displayTarget: "build.example.test",
                hostKeyAlias: nil,
                strictHostKeyChecking: "ask",
                projection: KwtSSHExecutionProjection(
                    arguments: ["-F", "/dev/null"]
                )
            ),
        ]
    )

    private static let prompt = KwtSSHLeasePrompt.fixture(
        id: "prompt-1",
        kind: .authentication,
        message: "Password:",
        route: route,
        hopIndex: 0
    )
}
