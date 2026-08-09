import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("SSH connection failure classification")
struct SSHConnectionFailureTests {
    @Test(
        "classifies SSH failures for native recovery",
        arguments: [
            (
                "Permission denied (publickey,password).",
                SSHConnectionFailure.Classification.Kind.authenticationRequired
            ),
            (
                "Host key verification failed.",
                SSHConnectionFailure.Classification.Kind.hostKeyReviewRequired
            ),
            (
                "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!",
                SSHConnectionFailure.Classification.Kind.hostKeyChanged
            ),
            (
                "Offending ED25519 key in /Users/example/.ssh/known_hosts:4",
                SSHConnectionFailure.Classification.Kind.hostKeyChanged
            ),
            (
                "ssh: connect to host example.test port 22: Network is unreachable",
                SSHConnectionFailure.Classification.Kind.transport
            ),
        ]
    )
    func classifiesRecovery(
        output: String,
        expected: SSHConnectionFailure.Classification.Kind
    ) {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: output
        )

        #expect(classification.kind == expected)
    }

    @Test("changed host keys require manual known-hosts remediation")
    func diagnosesChangedHostKey() {
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"
        )

        #expect(classification.kind == .hostKeyChanged)
        #expect(classification.diagnostic.recoverySuggestion.contains(
            "known-hosts"
        ))
    }

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
            status: AccountCommandRunner.timedOutStatus,
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
