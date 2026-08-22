import Foundation

struct SSHConnectionArgumentsCacheKey: Hashable, Sendable {
    let routeIdentity: String?
    let generation: UInt64?
    let arguments: [String]
}

/// The kwt-reviewed SSH arguments a presentation or command runs with,
/// frozen at the moment the owning connection was acquired. A snapshot made
/// from a connection keeps that ownership alive until every copy of the
/// snapshot is gone, so the arguments stay valid for as long as they can be
/// used; the connection releases itself when it is deallocated.
struct SSHConnectionArgumentsSnapshot: Sendable {
    let arguments: [String]
    let routeIdentity: String?
    let generation: UInt64?
    let cacheKey: SSHConnectionArgumentsCacheKey
    private let owner: KwtSSHConnection?

    init(arguments: [String]) {
        self.arguments = arguments
        routeIdentity = nil
        generation = nil
        cacheKey = SSHConnectionArgumentsCacheKey(
            routeIdentity: nil,
            generation: nil,
            arguments: arguments
        )
        owner = nil
    }

    init(_ connection: KwtSSHConnection) {
        arguments = connection.arguments
        routeIdentity = connection.routeIdentity
        generation = connection.generation
        cacheKey = SSHConnectionArgumentsCacheKey(
            routeIdentity: connection.routeIdentity,
            generation: connection.generation,
            arguments: connection.arguments
        )
        owner = connection
    }

    func invalidate() async {
        await owner?.invalidate()
    }

    /// Prefix OpenSSH prints (via the fail-closed proxy) when a lease could
    /// not be borrowed, so later classification sees the typed kwt code.
    static let failureMarker = "ghosthub-kwt-ssh-error:"

    /// Arguments that make OpenSSH fail with the lease error's typed code
    /// instead of opening an app-owned connection.
    static func failClosed(_ error: Error) -> SSHConnectionArgumentsSnapshot {
        let rawCode = (error as? KwtSSHLeaseError)?.code
            ?? "ssh_connection_failed"
        let code = rawCode.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
                .contains($0)
        } ? rawCode : "ssh_connection_failed"
        let proxyCommand = "/usr/bin/printf '"
            + failureMarker + code + "\\n' >&2; exit 255"
        return SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "ProxyCommand=\(proxyCommand)",
        ])
    }
}

extension KwtSSHConnection {
    /// Freezes this connection's arguments after confirming it still names
    /// the route an earlier probe reviewed.
    func snapshot(
        validating expected: SSHConnectionArgumentsSnapshot?
    ) async throws -> SSHConnectionArgumentsSnapshot {
        if let expectedRoute = expected?.routeIdentity,
           expectedRoute != routeIdentity {
            try? await release()
            throw KwtSSHLeaseError.routeChanged
        }
        return SSHConnectionArgumentsSnapshot(self)
    }
}
