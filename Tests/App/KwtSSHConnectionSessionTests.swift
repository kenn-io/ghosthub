import Foundation
import GhosthubSettings
import GhosthubTmux
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("kwt SSH connection prompts")
@MainActor
struct KwtSSHConnectionSessionTests {
    @Test("one lease carries host review and multi-round authentication")
    func carriesHostReviewAndAuthentication() async throws {
        let responses = LockedValue<[String]>([])
        let pool = KwtSSHConnectionPool { route, prompt in
            let hostKeyResponse = try await prompt(Self.hostKeyPrompt)
            responses.withLock { $0.append(hostKeyResponse) }
            let passwordResponse = try await prompt(Self.passwordPrompt)
            responses.withLock { $0.append(passwordResponse) }
            return KwtSSHTestLease(routeIdentity: route.routeIdentity)
        }
        let session = Self.session(pool: pool)

        let first = await session.pendingRequirement()
        let confirmation = try #require(first.value?.confirmation)
        #expect(confirmation.connectionDestination == "build.example.test")
        #expect(confirmation.destination == "relay.example.test")
        #expect(confirmation.algorithm == "ED25519")
        #expect(confirmation.fingerprint == "SHA256:relay")

        session.trust(confirmation)
        let second = await session.pendingRequirement()
        #expect(second.value?.requiresAuthentication == true)
        guard case let .prompt(prompt) = session.state else {
            Issue.record("expected credential prompt")
            return
        }
        #expect(prompt.message == "Password:")
        #expect(session.displayHost == SSHHostInfo(
            user: "operator",
            hostname: "192.0.2.20",
            port: 2200
        ))

        session.submit("secret")
        await waitUntilMainActor { session.state == .connected }
        #expect(responses.load() == ["yes", "secret"])
        #expect(session.arguments == ["-F", "/dev/null", "-S", "/tmp/socket"])
        try await session.release()
    }

    @Test("configuration changes remain a distinct recoverable state")
    func reportsConfigurationChanges() async {
        let pool = KwtSSHConnectionPool { _, _ in
            throw KwtSSHLeaseError.routeChanged
        }
        let session = Self.session(pool: pool)

        let result = await session.pendingRequirement()

        #expect(result.value == nil)
        #expect(session.state == .configurationChanged)
    }

    @Test("late connection waits fail after configuration changes")
    func lateConnectionWaitFailsAfterConfigurationChange() async {
        let pool = KwtSSHConnectionPool { _, _ in
            throw KwtSSHLeaseError.routeChanged
        }
        let session = Self.session(pool: pool)
        await waitUntilMainActor {
            session.state == .configurationChanged
        }

        await #expect(throws: KwtSSHLeaseError.self) {
            _ = try await session.takeConnection()
        }
    }

    @Test("canceling a connection waiter does not retain it")
    func canceledConnectionWaitReturns() async {
        let acquisition = AsyncStream<Void>.makeStream()
        let pool = KwtSSHConnectionPool { route, _ in
            var iterator = acquisition.stream.makeAsyncIterator()
            _ = await iterator.next()
            try Task.checkCancellation()
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity
            )
        }
        let session = Self.session(pool: pool)
        let completed = LockedValue(false)
        let waiter = Task {
            defer { completed.store(true) }
            _ = try await session.takeConnection()
        }

        waiter.cancel()
        await waitUntilMainActor(timeout: .milliseconds(100)) {
            completed.load()
        }
        #expect(completed.load())

        session.cancel()
        acquisition.continuation.finish()
        _ = await waiter.result
    }

    @Test("attachment handoff reports failure before an explicit retry")
    func takeConnectionReportsFailureBeforeRetry() async throws {
        let attempts = LockedValue(0)
        let pool = KwtSSHConnectionPool { route, _ in
            attempts.withLock { $0 += 1 }
            if attempts.load() == 1 {
                throw KwtSSHLeaseError.operationFailed(
                    code: "ssh_connection_failed",
                    message: "Connection failed.",
                    retryable: true
                )
            }
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity
            )
        }
        let session = Self.session(pool: pool)
        await #expect(throws: KwtSSHLeaseError.self) {
            _ = try await session.takeConnection()
        }
        #expect(session.state == .failed("Connection failed."))

        session.retry()

        let connection = try await session.takeConnection()
        #expect(connection.routeIdentity == Self.route.routeIdentity)
        #expect(attempts.load() == 2)
        try await connection.release()
    }

    @Test("an attachment connection can be handed off only once")
    func rejectsSecondConnectionHandoff() async throws {
        let acquisitions = LockedValue(0)
        let session = Self.session(
            pool: KwtSSHConnectionPool { route, _ in
                acquisitions.withLock { $0 += 1 }
                return KwtSSHTestLease(routeIdentity: route.routeIdentity)
            }
        )

        let connection = try await session.takeConnection()
        session.retry()
        await #expect(throws: KwtSSHLeaseError.self) {
            _ = try await session.takeConnection()
        }
        #expect(acquisitions.load() == 1)
        try await connection.release()
    }

    @Test("shared prompt cancellation transfers to the remaining session")
    func sharedPromptCancellationTransfersToRemainingSession() async {
        let routeIdentity = Self.route.routeIdentity
        let acquireCount = LockedValue(0)
        let pool = KwtSSHConnectionPool { _, respond in
            acquireCount.withLock { $0 += 1 }
            let response = try await respond(Self.passwordPrompt)
            #expect(response == "secret")
            return KwtSSHTestLease(
                routeIdentity: routeIdentity
            )
        }
        let route = Self.route
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in route },
            pool: pool
        )
        let owner = KwtSSHConnectionSession(
            host: SSHHostInfo(
                user: nil,
                hostname: "build.example.test",
                port: nil
            ),
            destination: "build.example.test",
            coordinator: coordinator
        )
        _ = await owner.pendingRequirement()
        let subscriber = KwtSSHConnectionSession(
            host: SSHHostInfo(
                user: nil,
                hostname: "build.example.test",
                port: nil
            ),
            destination: "build.example.test",
            coordinator: coordinator
        )
        try? await Task.sleep(for: .milliseconds(20))

        owner.cancel()

        await waitUntilMainActor(timeout: .seconds(1)) {
            if case .prompt = subscriber.state {
                return true
            }
            return false
        }
        subscriber.submit("secret")
        await waitUntilMainActor(timeout: .seconds(1)) {
            subscriber.state == .connected
        }
        #expect(acquireCount.load() == 1)
        try? await subscriber.release()
    }

    @Test("retry detaches blocked resolution before resolving again")
    func retryResolvesAgain() async {
        let firstStarted = AsyncStream<Void>.makeStream()
        let blocked = AsyncStream<Void>.makeStream()
        let resolveCount = LockedValue(0)
        let route = Self.route
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in
                resolveCount.withLock { $0 += 1 }
                if resolveCount.load() == 1 {
                    firstStarted.continuation.yield()
                    var iterator = blocked.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    try Task.checkCancellation()
                }
                return route
            },
            pool: KwtSSHConnectionPool { route, _ in
                KwtSSHTestLease(routeIdentity: route.routeIdentity)
            }
        )
        let session = KwtSSHConnectionSession(
            host: SSHHostInfo(
                user: nil,
                hostname: "build.example.test",
                port: nil
            ),
            destination: "build.example.test",
            coordinator: coordinator
        )
        var started = firstStarted.stream.makeAsyncIterator()
        _ = await started.next()

        session.retry()

        await waitUntilMainActor(timeout: .seconds(1)) {
            session.state == .connected
        }
        #expect(resolveCount.load() == 2)
        blocked.continuation.finish()
        try? await session.release()
    }

    @Test("terminal helper failure leaves connected state")
    func reportsTerminalHelperFailure() async {
        let terminal = AsyncStream<KwtSSHLeaseError?>.makeStream()
        let route = Self.route
        let pool = KwtSSHConnectionPool { _, _ in
            KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                terminalFailure: Task {
                    var iterator = terminal.stream.makeAsyncIterator()
                    return await iterator.next() ?? nil
                }
            )
        }
        let session = Self.session(pool: pool)
        await waitUntilMainActor { session.state == .connected }

        terminal.continuation.yield(.operationFailed(
            code: "ssh_connection_changed",
            message: "SSH connection changed.",
            retryable: false
        ))
        terminal.continuation.finish()

        await waitUntilMainActor(timeout: .seconds(1)) {
            session.state == .failed("SSH connection changed.")
        }
        #expect(session.arguments == nil)
    }

    @Test("expired attempts cannot publish after their retry is cancelled")
    func expiredAttemptCannotOverwriteCancelledRetry() async {
        let routeIdentity = Self.route.routeIdentity
        let promptFailed = AsyncStream<Void>.makeStream()
        let finishFailure = AsyncStream<Void>.makeStream()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let prompt = KwtSSHLeasePrompt(
            id: "expiring-password",
            kind: .authentication,
            message: "Password:",
            sensitive: true,
            deadline: formatter.string(from: Date().addingTimeInterval(0.05)),
            details: Self.passwordPrompt.details
        )
        let pool = KwtSSHConnectionPool { _, respond in
            do {
                _ = try await respond(prompt)
                Issue.record("expiring prompt unexpectedly received a response")
                return KwtSSHTestLease(
                    routeIdentity: routeIdentity
                )
            } catch {
                promptFailed.continuation.yield()
                var iterator = finishFailure.stream.makeAsyncIterator()
                _ = await iterator.next()
                throw error
            }
        }
        let session = Self.session(pool: pool)
        var failureEvents = promptFailed.stream.makeAsyncIterator()
        _ = await failureEvents.next()

        session.retry()
        session.cancel()
        finishFailure.continuation.yield()
        finishFailure.continuation.finish()

        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .starting)
    }

    @Test("an expired daemon prompt cannot hold the connection open")
    func expiresDaemonPrompt() async {
        let route = Self.route
        let prompt = KwtSSHLeasePrompt(
            id: "expired-password",
            kind: .authentication,
            message: "Password:",
            sensitive: true,
            deadline: "2000-01-01T00:00:00Z",
            details: Self.passwordPrompt.details
        )
        let pool = KwtSSHConnectionPool { _, respond in
            _ = try await respond(prompt)
            Issue.record("expired prompt unexpectedly received a response")
            return KwtSSHTestLease(routeIdentity: route.routeIdentity)
        }
        let session = Self.session(pool: pool)

        let result = await session.pendingRequirement()

        guard case let .failure(error) = result else {
            Issue.record("expected the expired prompt to fail")
            return
        }
        #expect(error.displayMessage == "SSH prompt timed out.")
        #expect(session.state == .failed("SSH prompt timed out."))
    }

    private static func session(
        pool: KwtSSHConnectionPool
    ) -> KwtSSHConnectionSession {
        let route = route
        return KwtSSHConnectionSession(
            host: SSHHostInfo(
                user: nil,
                hostname: "build.example.test",
                port: nil
            ),
            destination: "build.example.test",
            coordinator: KwtSSHAcquisitionCoordinator(
                resolve: { _ in route },
                pool: pool
            )
        )
    }

    private static let route = KwtSSHRouteSnapshot.fixture(
        logicalTarget: KwtSSHTarget(hostname: "build.example.test"),
        targets: [
            KwtSSHResolvedTarget(
                logicalTarget: KwtSSHTarget(hostname: "relay.example.test"),
                effectiveTarget: KwtSSHTarget(
                    hostname: "192.0.2.10",
                    user: "jump",
                    port: 22
                ),
                displayTarget: "relay.example.test",
                hostKeyAlias: nil,
                strictHostKeyChecking: "ask",
                projection: KwtSSHExecutionProjection(
                    arguments: ["-F", "/dev/null"],
                    privateConfig: []
                )
            ),
            KwtSSHResolvedTarget(
                logicalTarget: KwtSSHTarget(hostname: "build.example.test"),
                effectiveTarget: KwtSSHTarget(
                    hostname: "192.0.2.20",
                    user: "operator",
                    port: 2200
                ),
                displayTarget: "operator@build.example.test:2200",
                hostKeyAlias: nil,
                strictHostKeyChecking: "yes",
                projection: KwtSSHExecutionProjection(
                    arguments: ["-F", "/dev/null"],
                    privateConfig: []
                )
            ),
        ],
        observedAt: "2026-08-14T12:00:00Z"
    )

    private static let hostKeyPrompt = KwtSSHLeasePrompt.fixture(
        id: "prompt-host-key",
        kind: .hostKey,
        message: """
        The authenticity of host 'relay.example.test' can't be established.
        ED25519 key fingerprint is SHA256:relay.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """,
        deadline: "2099-08-14T12:02:00Z",
        route: route,
        hopIndex: 0,
        hostKey: KwtSSHHostKeyReview(
            host: "relay.example.test",
            algorithm: "ED25519",
            fingerprint: "SHA256:relay"
        )
    )

    private static let passwordPrompt = KwtSSHLeasePrompt.fixture(
        id: "prompt-password",
        kind: .authentication,
        message: "Password:",
        deadline: "2099-08-14T12:02:00Z",
        route: route,
        hopIndex: 1
    )
}

private extension Result where Success == SSHHostTrustRequirement,
    Failure == HostProbeError {
    var value: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}

private extension SSHHostTrustRequirement {
    var confirmation: SSHHostKeyConfirmation? {
        guard case let .confirmation(value) = self else { return nil }
        return value
    }

    var requiresAuthentication: Bool {
        guard case .authentication = self else { return false }
        return true
    }
}
