import GhosthubTransport

public enum ZellijSessionLifecycle {
    public static func killCommand(
        zellijPath: String,
        sessionName: String
    ) -> String {
        [zellijPath, "kill-session", "--", sessionName]
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
    }
}
