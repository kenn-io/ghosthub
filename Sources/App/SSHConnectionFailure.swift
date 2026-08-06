import Foundation
import GhosthubWorkspace

enum SSHConnectionFailure {
    struct Classification: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case transport
            case authenticationRequired
            case hostKeyReviewRequired
            case hostKeyChanged
        }

        var kind: Kind
        var diagnostic: RemoteHostDiagnostic
    }

    static func classify(
        status: Int32,
        output: String
    ) -> Classification {
        let normalized = output.lowercased()
        if status == 255, hostKeyChanged(normalized) {
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
        if status == 255, requiresHostKeyReview(normalized) {
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
        if status == 255, requiresAuthentication(normalized) {
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

        let summary: String
        if status == TmuxBinaryResolver.timedOutStatus
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
}
