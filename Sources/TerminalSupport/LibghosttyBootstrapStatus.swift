public struct LibghosttyBootstrapStatus: Equatable, Sendable {
    public var isReady: Bool
    public var artifactRoot: String
    public var bootstrapCommand: String
    public var message: String?

    public static func ready(
        artifactRoot: String = LibghosttyBootstrapSupport.artifactRoot,
        bootstrapCommand: String = LibghosttyBootstrapSupport.bootstrapCommand
    ) -> Self {
        Self(
            isReady: true,
            artifactRoot: artifactRoot,
            bootstrapCommand: bootstrapCommand,
            message: nil
        )
    }

    public static func missing(
        artifactRoot: String = LibghosttyBootstrapSupport.artifactRoot,
        bootstrapCommand: String = LibghosttyBootstrapSupport.bootstrapCommand,
        message: String = LibghosttyBootstrapSupport.missingArtifactsMessage
    ) -> Self {
        Self(
            isReady: false,
            artifactRoot: artifactRoot,
            bootstrapCommand: bootstrapCommand,
            message: message
        )
    }
}

public enum LibghosttyBootstrapSupport {
    public static let artifactRoot = ".build/libghostty"
    public static let bootstrapCommand = "make bootstrap-libghostty"
    public static let missingArtifactsMessage =
        "libghostty bootstrap artifacts are missing or stale. Run `\(bootstrapCommand)` from the repo root."
}
