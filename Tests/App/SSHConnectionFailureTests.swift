import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("SSH connection failure classification")
struct SSHConnectionFailureTests {
    @Test(
        "only authentication failures request secure entry",
        arguments: [
            ("Permission denied (publickey,password).", true),
            (
                "ssh: connect to host example.test port 22: Connection refused",
                false
            ),
            (
                "ssh: Could not resolve hostname example.test: unknown host",
                false
            ),
            (
                "ssh: connect to host example.test port 22: Operation timed out",
                false
            ),
        ]
    )
    func classifiesFailure(output: String, requiresAuthentication: Bool) {
        let diagnostic = SSHConnectionFailure.diagnostic(
            status: 255,
            output: output
        )

        #expect(
            (diagnostic.code == .sshAuthenticationFailed)
                == requiresAuthentication
        )
    }

    @Test("a process timeout keeps its specific connection diagnosis")
    func classifiesProcessTimeout() {
        let diagnostic = SSHConnectionFailure.diagnostic(
            status: TmuxBinaryResolver.timedOutStatus,
            output: ""
        )

        #expect(diagnostic.code == .sshConnectionFailed)
        #expect(diagnostic.summary == "The SSH connection timed out.")
    }

    @Test("remote command permission failures do not request credentials")
    func rejectsNonTransportPermissionFailure() {
        let diagnostic = SSHConnectionFailure.diagnostic(
            status: 1,
            output: "remote command: permission denied"
        )

        #expect(diagnostic.code == .sshConnectionFailed)
    }
}
