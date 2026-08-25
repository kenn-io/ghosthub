import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("SSH destinations")
struct SSHDestinationTests {
    @Test("renders explicit user, IPv6 host, and port")
    func rendersIPv6Destination() {
        #expect(SSHDestination.render(SSHHostInfo(
            user: "developer",
            hostname: "2001:db8::10",
            port: 2200
        )) == "developer@[2001:db8::10]:2200")
    }

    @Test("does not invent optional destination fields")
    func rendersBareHost() {
        #expect(SSHDestination.render(SSHHostInfo(
            user: nil,
            hostname: "build.example.test",
            port: nil
        )) == "build.example.test")
    }
}
