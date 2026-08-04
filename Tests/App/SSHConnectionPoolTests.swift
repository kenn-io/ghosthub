import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("SSH connection pool")
struct SSHConnectionPoolTests {
    @Test("authentication keeps password handling inside OpenSSH")
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

        #expect(arguments.first == "/usr/bin/ssh")
        #expect(arguments.contains("BatchMode=no"))
        #expect(arguments.contains("ControlMaster=yes"))
        #expect(arguments.contains("ControlPersist=no"))
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
}
