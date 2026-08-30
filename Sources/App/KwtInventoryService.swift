import Foundation
import GhosthubTransport

private actor KwtInventoryLoadCoordinator {
    static let shared = KwtInventoryLoadCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var activeHosts: Set<SSHHostInfo> = []
    private var waitersByHost: [SSHHostInfo: [Waiter]] = [:]

    func withExclusiveLoad<Value: Sendable>(
        host: SSHHostInfo,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(host: host)
        defer { release(host: host) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(host: SSHHostInfo) async throws {
        try Task.checkCancellation()
        if activeHosts.insert(host).inserted {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitersByHost[host, default: []].append(Waiter(
                    id: waiterID,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, host: host)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, host: SSHHostInfo) {
        guard var waiters = waitersByHost[host],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = waiters.remove(at: index)
        waitersByHost[host] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(host: SSHHostInfo) {
        guard var waiters = waitersByHost[host], !waiters.isEmpty else {
            activeHosts.remove(host)
            return
        }
        let waiter = waiters.removeFirst()
        waitersByHost[host] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume()
    }
}

struct KwtInventoryService: Sendable {
    private enum RouteExpectation: Sendable {
        case any
        case exact(String?)
    }

    private let client: KwtInventoryClient
    private let lease: KwtSSHCommandLease

    init(
        client: KwtInventoryClient = KwtInventoryClient(),
        lease: KwtSSHCommandLease = KwtSSHCommandLease()
    ) {
        self.client = client
        self.lease = lease
    }

    func load(from host: CommandHost) async throws -> KwtHostInventory {
        try await load(from: host, routeExpectation: .any)
    }

    func load(
        from host: CommandHost,
        expectedRouteIdentity: String?
    ) async throws -> KwtHostInventory {
        try await load(
            from: host,
            routeExpectation: .exact(expectedRouteIdentity)
        )
    }

    private func load(
        from host: CommandHost,
        routeExpectation: RouteExpectation
    ) async throws -> KwtHostInventory {
        guard case let .ssh(info) = host else {
            if case let .exact(expected) = routeExpectation,
               expected != nil {
                throw KwtSSHLeaseError.routeChanged
            }
            return try await client.load(from: host)
        }

        return try await KwtInventoryLoadCoordinator.shared.withExclusiveLoad(
            host: info
        ) {
            try await lease.withConnection(on: host) { connection in
                guard let connection else {
                    throw KwtInventoryError.sshLeaseRequired(
                        host: info.displayName
                    )
                }
                if case let .exact(expected) = routeExpectation,
                   connection.routeIdentity != expected {
                    throw KwtSSHLeaseError.routeChanged
                }
                return try await client.load(
                    from: host,
                    sshConnection: connection
                )
            }
        }
    }
}
