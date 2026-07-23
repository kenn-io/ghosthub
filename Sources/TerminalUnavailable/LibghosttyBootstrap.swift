import GhosthubTerminalSupport

public enum LibghosttyBootstrap {
    public static func status() -> LibghosttyBootstrapStatus {
        .missing()
    }

    public static func preconditionReady(file: StaticString = #file, line: UInt = #line) {
        preconditionFailure(LibghosttyBootstrapSupport.missingArtifactsMessage, file: file, line: line)
    }
}
