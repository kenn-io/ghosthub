import Foundation
import GhosthubTransport
@testable import GhosthubApp

final class KwtSSHTestLease: KwtSSHLeaseHolding, @unchecked Sendable {
    let result: KwtSSHLeaseResult
    let terminalFailure: Task<KwtSSHLeaseError?, Never>

    private let releaseAction: @Sendable () async throws -> Void

    init(
        routeIdentity: String,
        generation: UInt64 = 1,
        arguments: [String] = [
            "-F", "/dev/null", "-S", "/tmp/socket",
        ],
        terminalFailure: Task<KwtSSHLeaseError?, Never> = Task { nil },
        releaseCount: LockedValue<Int>? = nil,
        onRelease: @escaping @Sendable () async throws -> Void = {}
    ) {
        result = KwtSSHLeaseResult(
            leaseID: "lease-1",
            routeIdentity: routeIdentity,
            generation: generation,
            mode: .multiplexed,
            arguments: arguments
        )
        self.terminalFailure = terminalFailure
        releaseAction = {
            releaseCount?.withLock { $0 += 1 }
            try await onRelease()
        }
    }

    func release(timeout _: Duration) async throws {
        try await releaseAction()
    }
}

extension KwtSSHRouteSnapshot {
    static func fixture(
        logicalTarget: KwtSSHTarget = KwtSSHTarget(
            hostname: "build.example.test"
        ),
        targets: [KwtSSHResolvedTarget] = [],
        routeIdentity: String = "sha256:route",
        observedAt: String = "2026-08-15T12:00:00Z"
    ) -> KwtSSHRouteSnapshot {
        KwtSSHRouteSnapshot(
            logicalTarget: logicalTarget,
            targets: targets,
            routeIdentity: routeIdentity,
            projectionPolicy: KwtSSHRouteClient.supportedProjectionPolicy,
            observedAt: observedAt
        )
    }
}

extension KwtSSHLeasePrompt {
    static func fixture(
        id: String,
        kind: KwtSSHLeasePromptKind,
        message: String,
        deadline: String = "2099-08-15T12:00:00Z",
        route: KwtSSHRouteSnapshot,
        hopIndex: Int,
        hostKey: KwtSSHHostKeyReview? = nil
    ) -> KwtSSHLeasePrompt {
        let target = route.targets[hopIndex]
        return KwtSSHLeasePrompt(
            id: id,
            kind: kind,
            message: message,
            sensitive: kind == .authentication,
            deadline: deadline,
            details: KwtSSHLeasePromptDetails(
                logicalTarget: target.logicalTarget,
                effectiveTarget: target.effectiveTarget,
                displayTarget: target.displayTarget,
                hopIndex: hopIndex,
                hopCount: route.targets.count,
                hostKey: hostKey
            )
        )
    }
}

extension KwtSSHConnectionSession {
    /// A session whose coordinator resolves every destination to `route`.
    convenience init(
        route: KwtSSHRouteSnapshot,
        host: SSHHostInfo,
        destination: String,
        pool: KwtSSHConnectionPool
    ) {
        self.init(
            host: host,
            destination: destination,
            coordinator: KwtSSHAcquisitionCoordinator(
                resolve: { _ in route },
                pool: pool
            )
        )
    }
}
