import Foundation
import GhosthubWorkspace

enum SSHConnectionFailure {
    static func diagnostic(
        status: Int32,
        output: String
    ) -> RemoteHostDiagnostic {
        let normalized = output.lowercased()
        if status == 255, requiresAuthentication(normalized) {
            return RemoteHostDiagnostic(
                code: .sshAuthenticationFailed,
                severity: .error,
                summary: "SSH authentication is required.",
                recoverySuggestion:
                "Enter the password or verification code requested by OpenSSH."
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
        return RemoteHostDiagnostic(
            code: .sshConnectionFailed,
            severity: .error,
            summary: summary,
            recoverySuggestion:
            "Check the destination, network access, and SSH server, then retry."
        )
    }

    private static func requiresAuthentication(_ normalized: String) -> Bool {
        normalized.contains("permission denied")
            || normalized.contains("authentication failed")
            || normalized.contains(
                "no supported authentication methods available"
            )
            || normalized.contains("too many authentication failures")
    }
}
