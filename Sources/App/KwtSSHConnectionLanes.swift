import Foundation

/// What an SSH connection will carry, which decides the master it uses.
enum KwtSSHConnectionPurpose: Sendable {
    /// Short-lived commands. They share the route's primary master and wait
    /// for a free session there.
    case commands
    /// One interactive terminal for its whole lifetime. It holds a session on
    /// the first master with room, opening another master when all are full.
    case terminal
}

/// One shared connection pool per kwt master index. Index 0 is each route's
/// primary master; every other index is a separate OpenSSH connection to the
/// same route, so terminals can exceed one connection's session limit.
final class KwtSSHConnectionLanes: @unchecked Sendable {
    static let shared = KwtSSHConnectionLanes(primary: .shared)

    /// kwt accepts connection indexes 0 through 15.
    static let maximumLanes = 16

    private let lock = NSLock()
    private var pools: [Int: KwtSSHConnectionPool]
    private let makePool: @Sendable (Int) -> KwtSSHConnectionPool

    init(
        primary: KwtSSHConnectionPool,
        makePool: @escaping @Sendable (Int) -> KwtSSHConnectionPool = {
            KwtSSHConnectionPool(connection: $0)
        }
    ) {
        pools = [0: primary]
        self.makePool = makePool
    }

    func pool(_ index: Int) -> KwtSSHConnectionPool {
        lock.withLock {
            if let pool = pools[index] {
                return pool
            }
            let pool = makePool(index)
            pools[index] = pool
            return pool
        }
    }

    var activePools: [KwtSSHConnectionPool] {
        lock.withLock {
            pools.keys.sorted().compactMap { pools[$0] }
        }
    }

    func releaseAll() async throws {
        var firstError: Error?
        for pool in activePools.reversed() {
            do {
                try await pool.releaseAll()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }
}
