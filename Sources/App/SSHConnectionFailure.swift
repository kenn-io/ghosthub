import Foundation
import GhosthubHerdr
import GhosthubWorkspace
import GhosthubZellij

enum SSHConnectionFailure {
    struct Classification: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case transport
            case authenticationRequired
            case hostKeyReviewRequired
            case hostKeyChanged
            case configurationChanged
        }

        var kind: Kind
        var diagnostic: RemoteHostDiagnostic
        /// OpenSSH could not use the daemon-owned master, so the pooled
        /// lease must be re-established before this route is used again.
        var connectionUnusable = false
    }

    static func classify(
        status: Int32,
        output: String
    ) -> Classification {
        var classification = classifyOutput(status: status, output: output)
        classification.connectionUnusable = indicatesUnusableConnection(
            status: status,
            output: output
        )
        return classification
    }

    private static func classifyOutput(
        status: Int32,
        output: String
    ) -> Classification {
        let normalized = output.lowercased()
        if status == 255, let code = typedFailureCode(normalized) {
            return typedFailure(code, diagnostic: normalized)
        }
        if status == 255,
           let recovery = recoveryClassification(normalized) {
            return recovery
        }

        let summary: String
        if status == AccountCommandRunner.timedOutStatus
            || normalized.contains("connection timed out")
            || normalized.contains("operation timed out") {
            summary = "The SSH connection timed out."
        } else if normalized.contains("could not resolve hostname")
            || normalized.contains("name or service not known") {
            summary = "SSH could not resolve the host name."
        } else if normalized.contains("connection refused") {
            summary = "The SSH connection was refused."
        } else if normalized.contains("no route to host")
            || normalized.contains("network is unreachable") {
            summary = "SSH could not reach the host."
        } else {
            summary = "SSH could not connect to the host."
        }
        return Classification(
            kind: .transport,
            diagnostic: RemoteHostDiagnostic(
                code: .sshConnectionFailed,
                severity: .error,
                summary: summary,
                recoverySuggestion:
                "Check the destination, network access, and SSH server, then retry."
            )
        )
    }

    static func diagnostic(
        status: Int32,
        output: String
    ) -> RemoteHostDiagnostic {
        classify(status: status, output: output).diagnostic
    }

    /// Classifies a failure to borrow a kwt lease before any command ran.
    static func classify(leaseError: Error) -> Classification {
        guard let leaseError = leaseError as? KwtSSHLeaseError else {
            return classify(status: 255, output: leaseError.localizedDescription)
        }
        return typedFailure(
            leaseError.code,
            diagnostic: leaseError.localizedDescription.lowercased()
        )
    }

    /// True when OpenSSH could not reach the daemon-owned master and fell
    /// through to the lease's fail-closed proxy, so the master must be
    /// re-established before the route is used again.
    static func indicatesUnusableConnection(
        status: Int32,
        output: String
    ) -> Bool {
        guard status == 255 else { return false }
        let normalized = output.lowercased()
        return normalized.contains("connection closed by unknown port 65535")
            || normalized.contains("control socket connect(")
    }

    static func indicatesUnusableConnection(
        _ error: ZellijCommandError
    ) -> Bool {
        guard case let .commandFailed(status, stderr) = error else {
            return false
        }
        return indicatesUnusableConnection(status: status, output: stderr)
    }

    static func indicatesUnusableConnection(
        _ error: HerdrCommandError
    ) -> Bool {
        guard case let .commandFailed(status, stderr) = error else {
            return false
        }
        return indicatesUnusableConnection(status: status, output: stderr)
    }

    static func indicatesUnusableConnection(
        _ error: HerdrSessionLifecycleError
    ) -> Bool {
        guard case let .commandFailed(status, _, message) = error else {
            return false
        }
        return indicatesUnusableConnection(status: status, output: message)
    }

    static func presentationConnectionUnusable(
        recordedExitCode: UInt32?,
        childExitCode: UInt32?
    ) -> Bool {
        (recordedExitCode ?? childExitCode) == 255
    }

    private static func requiresAuthentication(_ normalized: String) -> Bool {
        normalized.contains("permission denied")
            || normalized.contains("authentication failed")
            || normalized.contains(
                "no supported authentication methods available"
            )
            || normalized.contains("too many authentication failures")
    }

    private static func requiresHostKeyReview(_ normalized: String) -> Bool {
        normalized.contains("host key verification failed")
    }

    private static func hostKeyChanged(_ normalized: String) -> Bool {
        normalized.contains("remote host identification has changed")
            || (normalized.contains("offending ")
                && normalized.contains(" key in "))
    }

    private static func typedFailureCode(_ output: String) -> String? {
        guard let marker = output.range(
            of: SSHConnectionArgumentsSnapshot.failureMarker
        ) else { return nil }
        let suffix = output[marker.upperBound...]
        let code = suffix.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return code.isEmpty ? nil : String(code)
    }

    private static func recoveryClassification(
        _ normalized: String
    ) -> Classification? {
        if hostKeyChanged(normalized) {
            return Classification(
                kind: .hostKeyChanged,
                diagnostic: RemoteHostDiagnostic(
                    code: .sshConnectionFailed,
                    severity: .error,
                    summary: "The SSH host identity changed.",
                    recoverySuggestion:
                    "Verify the host outside Ghosthub, then update its known-hosts entry before reconnecting."
                )
            )
        }
        if requiresHostKeyReview(normalized) {
            return Classification(
                kind: .hostKeyReviewRequired,
                diagnostic: RemoteHostDiagnostic(
                    code: .sshConnectionFailed,
                    severity: .error,
                    summary: "The SSH host key needs review.",
                    recoverySuggestion:
                    "Review and approve the host identity before reconnecting."
                )
            )
        }
        if requiresAuthentication(normalized) {
            return Classification(
                kind: .authenticationRequired,
                diagnostic: RemoteHostDiagnostic(
                    code: .sshAuthenticationFailed,
                    severity: .error,
                    summary: "SSH authentication is required.",
                    recoverySuggestion:
                    "Enter the password or verification code requested by OpenSSH."
                )
            )
        }
        return nil
    }

    private static func typedFailure(
        _ code: String,
        diagnostic: String? = nil
    ) -> Classification {
        switch code {
        case "ssh_interaction_required", "ssh_prompt_rejected",
             "ssh_prompt_timed_out":
            return Classification(
                kind: .authenticationRequired,
                diagnostic: RemoteHostDiagnostic(
                    code: .sshAuthenticationFailed,
                    severity: .error,
                    summary: "SSH authentication or host review is required.",
                    recoverySuggestion:
                    "Review the connection in an active Ghosthub window."
                )
            )
        case "ssh_configuration_changed", "ssh_invalid_target",
             "ssh_route_unreviewable":
            return Classification(
                kind: .configurationChanged,
                diagnostic: RemoteHostDiagnostic(
                    code: .sshConnectionFailed,
                    severity: .error,
                    summary: "The effective SSH configuration changed or cannot be reviewed.",
                    recoverySuggestion:
                    "Review the host's SSH configuration before reconnecting."
                )
            )
        case "ssh_unsupported_version", "ssh_persistent_unsupported":
            return Classification(
                kind: .configurationChanged,
                diagnostic: RemoteHostDiagnostic(
                    code: .sshConnectionFailed,
                    severity: .error,
                    summary: "Ghosthub's SSH helper is out of date for this connection.",
                    recoverySuggestion:
                    "Restart Ghosthub to relaunch its bundled SSH helper, then reconnect."
                )
            )
        default:
            if let diagnostic,
               let recovery = recoveryClassification(diagnostic) {
                return recovery
            }
            return Classification(
                kind: .transport,
                diagnostic: RemoteHostDiagnostic(
                    code: .sshConnectionFailed,
                    severity: .error,
                    summary: "The kwt SSH connection failed (\(code)).",
                    recoverySuggestion:
                    "Check the destination, network access, and SSH server, then retry."
                )
            )
        }
    }
}
