import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("SSH connection pool")
struct SSHConnectionPoolTests {
    @Test("authentication accepts a native secure response through OpenSSH")
    func authenticationUsesInteractiveOpenSSHMaster() {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: 22
        )
        let arguments = SSHConnectionPool.authenticationArguments(
            for: host,
            controlPath: "/tmp/ghosthub-test/control-%C",
            hostKeyArguments: ["-o", "StrictHostKeyChecking=yes"]
        )

        #expect(arguments.first == "-N")
        #expect(arguments.contains("BatchMode=no"))
        #expect(arguments.contains("ControlMaster=yes"))
        #expect(arguments.contains("ControlPersist=no"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.suffix(4) == [
            "-p", "22", "--", "operator@build.example.test",
        ])
    }

    @Test("connection checks preserve the explicit destination")
    func checkUsesSameControlIdentity() {
        let arguments = SSHConnectionPool.checkArguments(
            for: SSHHostInfo(
                user: "operator",
                hostname: "build.example.test",
                port: 2200
            ),
            controlPath: "/tmp/ghosthub-test/control-%C"
        )

        #expect(arguments == [
            "-O", "check",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=/tmp/ghosthub-test/control-%C",
            "-p", "2200",
            "--", "operator@build.example.test",
        ])
    }

    @Test("control sockets are scoped to the resolved SSH route")
    func controlSocketUsesResolvedRoute() {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: 22
        )
        let directName = SSHConnectionPool.controlName(
            for: host,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil,
                    hostname: "build.internal",
                    port: 22
                )
            }
        )
        let proxiedName = SSHConnectionPool.controlName(
            for: host,
            configurationProvider: { requestedHost in
                if requestedHost.hostname == "relay.example.test" {
                    return EffectiveSSHConfiguration(
                        user: "relay-user",
                        strictHostKeyChecking: "yes",
                        proxyJump: nil,
                        proxyCommand: nil,
                        hostname: "relay.internal",
                        port: 2200
                    )
                }
                return EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: "relay.example.test",
                    proxyCommand: nil,
                    hostname: "build.internal",
                    port: 22
                )
            }
        )

        #expect(directName != proxiedName)
        #expect(proxiedName.hasPrefix("control-"))
        #expect(proxiedName.count <= 40)
    }
}
