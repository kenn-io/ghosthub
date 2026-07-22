public struct GhosttyBootstrapStatus: Equatable, Sendable {
    public var isReady: Bool
    public var artifactRoot: String
    public var bootstrapCommand: String
    public var message: String?

    public static func ready(
        artifactRoot: String = GhosttyBootstrapSupport.artifactRoot,
        bootstrapCommand: String = GhosttyBootstrapSupport.bootstrapCommand
    ) -> Self {
        Self(
            isReady: true,
            artifactRoot: artifactRoot,
            bootstrapCommand: bootstrapCommand,
            message: nil
        )
    }

    public static func missing(
        artifactRoot: String = GhosttyBootstrapSupport.artifactRoot,
        bootstrapCommand: String = GhosttyBootstrapSupport.bootstrapCommand,
        message: String = GhosttyBootstrapSupport.missingArtifactsMessage
    ) -> Self {
        Self(
            isReady: false,
            artifactRoot: artifactRoot,
            bootstrapCommand: bootstrapCommand,
            message: message
        )
    }
}

public enum GhosttyBootstrapSupport {
    public static let artifactRoot = ".build/libghostty"
    public static let bootstrapCommand = "make bootstrap-libghostty"
    public static let missingArtifactsMessage =
        "libghostty bootstrap artifacts are missing or stale. Run `\(bootstrapCommand)` from the repo root."
}
