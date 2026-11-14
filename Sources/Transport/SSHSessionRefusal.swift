import Foundation

/// OpenSSH's report that a shared connection refused another session, which
/// happens before the remote command starts. The server allows only so many
/// sessions per connection (`MaxSessions`).
public enum SSHSessionRefusal {
    public static let explanation =
        "The SSH connection to this host refused another session."

    /// The captured stream may also hold the remote command's standard
    /// error, so callers decide separately whether repeating is safe.
    public static func matches(status: Int32, output: String) -> Bool {
        guard status == 255 else { return false }
        return output.lowercased().contains(
            "mux_client_request_session: session request failed: "
                + "session open refused by peer"
        )
    }

    /// Describes a backend command failure without blaming the backend when
    /// the SSH connection refused to start it.
    public static func describeCommandFailure(
        tool: String,
        status: Int32,
        detail: String
    ) -> String {
        if matches(status: status, output: detail) {
            return "\(explanation) \(tool) did not run."
        }
        return detail.isEmpty
            ? "\(tool) exited with status \(status)."
            : "\(tool) exited with status \(status): \(detail)"
    }
}
