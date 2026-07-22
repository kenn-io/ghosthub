import GhosthubTerminalSupport

public enum GhosttyBootstrap {
    public static func status() -> GhosttyBootstrapStatus {
        .missing()
    }

    public static func preconditionReady(file: StaticString = #file, line: UInt = #line) {
        preconditionFailure(GhosttyBootstrapSupport.missingArtifactsMessage, file: file, line: line)
    }
}
