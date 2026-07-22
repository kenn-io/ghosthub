import GhosthubTerminalSupport
import GhosttyKit

private let ghosttyLinkAnchor = ghostty_init

public enum GhosttyBootstrap {
    public static func status() -> GhosttyBootstrapStatus {
        _ = ghosttyLinkAnchor
        return .ready()
    }

    public static func preconditionReady(file: StaticString = #file, line: UInt = #line) {
        _ = ghosttyLinkAnchor
    }
}
