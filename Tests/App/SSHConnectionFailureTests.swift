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
            (
                "ghosthub-kwt-ssh-error:ssh_interaction_required",
                SSHConnectionFailure.Classification.Kind.authenticationRequired
            ),
            (
                "ghosthub-kwt-ssh-error:ssh_configuration_changed",
                SSHConnectionFailure.Classification.Kind.configurationChanged
            ),
            (
                "ghosthub-kwt-ssh-error:ssh_cleanup_failed",
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

    @Test(
        "only a lost daemon master marks the pooled connection unusable",
        arguments: [
            (255, "Connection closed by UNKNOWN port 65535", true),
            (
                255,
                "Control socket connect(/tmp/kwt.sock): Connection refused",
                true
            ),
            (
                255,
                """
                mux_client_request_session: session request failed: Session open refused by peer
                Connection closed by UNKNOWN port 65535
                """,
                false
            ),
            (255, "Permission denied (publickey,password).", false),
            (1, "Connection closed by UNKNOWN port 65535", false),
            (
                255,
                "ssh: connect to host example.test port 22: Network is unreachable",
                false
            ),
        ]
    )
    func detectsUnusableConnection(
        status: Int32,
        output: String,
        expected: Bool
    ) {
        #expect(
            SSHConnectionFailure.indicatesUnusableConnection(
                status: status,
                output: output
            ) == expected
        )
        #expect(
            SSHConnectionFailure.classify(status: status, output: output)
                .connectionUnusable == expected
        )
    }

    @Test("lease borrow failures classify by their typed code")
    func classifiesLeaseErrors() {
        let interaction = SSHConnectionFailure.classify(
            leaseError: KwtSSHLeaseError.operationFailed(
                code: "ssh_interaction_required",
                message: "SSH authentication requires an active window.",
                retryable: false
            )
        )
        #expect(interaction.kind == .authenticationRequired)
        #expect(!interaction.connectionUnusable)

        let changed = SSHConnectionFailure.classify(
            leaseError: KwtSSHLeaseError.routeChanged
        )
        #expect(changed.kind == .configurationChanged)
    }

    @Test("helper version drift is not blamed on the SSH configuration")
    func classifiesUnsupportedHelperVersion() {
        let unsupported = SSHConnectionFailure.classify(
            leaseError: KwtSSHLeaseError.operationFailed(
                code: "ssh_unsupported_version",
                message: "kwt lease protocol version is unsupported.",
                retryable: false
            )
        )
        let changed = SSHConnectionFailure.classify(
            leaseError: KwtSSHLeaseError.routeChanged
        )

        #expect(unsupported.kind == .configurationChanged)
        #expect(unsupported.diagnostic.summary.contains("helper"))
        #expect(unsupported.diagnostic.summary != changed.diagnostic.summary)
    }

    @Test(
        "only transport-class lease failures allow automatic retry",
        arguments: [
            (KwtSSHLeaseError.acquisitionTimedOut, true),
            (KwtSSHLeaseError.commandFailed(status: 255), true),
            (KwtSSHLeaseError.commandFailed(status: 1), false),
            (KwtSSHLeaseError.helperUnavailable, false),
            (KwtSSHLeaseError.launchFailed, false),
            (KwtSSHLeaseError.poolClosed, false),
            (
                KwtSSHLeaseError.operationFailed(
                    code: "ssh_connection_failed",
                    message: "ssh: connect to host example.test port 22: No route to host",
                    retryable: true
                ),
                true
            ),
            (
                KwtSSHLeaseError.operationFailed(
                    code: "ssh_connection_failed",
                    message: "ssh: connect to host example.test port 22: No route to host",
                    retryable: false
                ),
                false
            ),
            (
                KwtSSHLeaseError.operationFailed(
                    code: "ssh_connection_failed",
                    message: "Permission denied (publickey,password).",
                    retryable: true
                ),
                false
            ),
        ]
    )
    func classifiesRetryableTransportFailures(
        error: KwtSSHLeaseError,
        retryable: Bool
    ) {
        let classification = SSHConnectionFailure.retryableTransportFailure(
            error
        )

        #expect((classification != nil) == retryable)
        #expect(classification.map(\.kind) == (retryable ? .transport : nil))
    }

    @Test("an acquisition timeout keeps its specific connection diagnosis")
    func classifiesAcquisitionTimeout() {
        let classification = SSHConnectionFailure.classify(
            leaseError: KwtSSHLeaseError.acquisitionTimedOut
        )

        #expect(classification.kind == .transport)
        #expect(
            classification.diagnostic.summary
                == "The SSH connection timed out."
        )
    }

    @Test(
        "generic lease failures preserve native recovery signals",
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
        ]
    )
    func classifiesGenericLeaseDiagnostics(
        message: String,
        expected: SSHConnectionFailure.Classification.Kind
    ) {
        let classification = SSHConnectionFailure.classify(
            leaseError: KwtSSHLeaseError.operationFailed(
                code: "ssh_connection_failed",
                message: message,
                retryable: true
            )
        )

        #expect(classification.kind == expected)
    }
}
