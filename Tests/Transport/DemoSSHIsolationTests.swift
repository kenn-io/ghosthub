import Testing
@testable import GhosthubTransport

@Suite("Demo SSH isolation")
struct DemoSSHIsolationTests {
    @Test("normal environments do not alter SSH arguments")
    func normalEnvironment() {
        #expect(demoSSHIsolationArguments(environment: [:]).isEmpty)
    }

    @Test("validated demo paths isolate account SSH state")
    func validatedDemoEnvironment() {
        let scratch = "/tmp/ghosthub demo"

        #expect(demoSSHIsolationArguments(environment: [
            "GHOSTHUB_DEMO_SCRATCH": scratch,
            "GHOSTHUB_DEMO_SSH_DIR": "\(scratch)/ssh",
        ]) == [
            "-F", "\(scratch)/ssh/config",
            "-o", "UserKnownHostsFile=\(scratch)/ssh/known_hosts",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ProxyCommand=none",
            "-o", "ProxyJump=none",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ])
    }
}
