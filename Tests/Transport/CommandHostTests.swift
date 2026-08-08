import Foundation
import Testing
@testable import GhosthubTransport

@Suite("Command hosts")
struct CommandHostTests {
    @Test("host display names preserve destination identity")
    func displayNames() {
        #expect(
            SSHHostInfo(
                user: "alice", hostname: "example.com", port: 22
            ).displayName == "alice@example.com"
        )
        #expect(
            SSHHostInfo(
                user: "alice", hostname: "example.com", port: 2222
            ).displayName == "alice@example.com:2222"
        )
        #expect(CommandHost.local.displayName == "localhost")
        #expect(!CommandHost.local.isRemote)
        #expect(CommandHost.ssh(SSHHostInfo(
            user: nil,
            hostname: "example.com",
            port: nil
        )).isRemote)
    }

    @Test("host identity is codable")
    func hostIdentityCodable() throws {
        let original = CommandHost.ssh(SSHHostInfo(
            user: "bob", hostname: "server.io", port: 2222
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommandHost.self, from: data)
        #expect(original == decoded)
    }
}
