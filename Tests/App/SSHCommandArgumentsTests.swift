import GhosthubTransport
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("SSH command arguments")
struct SSHCommandArgumentsTests {
    @Test("demo isolation bypasses account SSH argument resolution")
    func demoIsolationBypassesAccountState() {
        let normalCallCount = Mutex(0)
        let scratch = "/tmp/ghosthub-demo"

        let arguments = SSHCommandArguments.noninteractive(
            for: host,
            environment: [
                "GHOSTHUB_DEMO_SCRATCH": scratch,
                "GHOSTHUB_DEMO_SSH_DIR": "\(scratch)/ssh",
            ],
            normalArgumentsProvider: { _ in
                normalCallCount.withLock { $0 += 1 }
                return ["REAL_SSH_STATE"]
            }
        )

        #expect(normalCallCount.withLock { $0 } == 0)
        #expect(arguments.contains("\(scratch)/ssh/config"))
        #expect(arguments.contains("ControlPath=none"))
        #expect(!arguments.contains("REAL_SSH_STATE"))
    }

    @Test("normal mode preserves account SSH arguments")
    func normalModeUsesAccountState() {
        let arguments = SSHCommandArguments.noninteractive(
            for: host,
            environment: [:],
            normalArgumentsProvider: { _ in ["ACCOUNT_SSH_STATE"] }
        )

        #expect(arguments == ["ACCOUNT_SSH_STATE"])
    }

    private var host: SSHHostInfo {
        SSHHostInfo(
            user: "demo",
            hostname: "ghosthub-demo-remote",
            port: nil
        )
    }
}
