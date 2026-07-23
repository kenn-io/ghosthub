import GhosthubTerminalSupport
import GhosttyKit

private let ghosttyLinkAnchor = ghostty_init

public enum LibghosttyBootstrap {
    public static func status() -> LibghosttyBootstrapStatus {
        _ = ghosttyLinkAnchor
        return .ready()
    }

    public static func preconditionReady(file: StaticString = #file, line: UInt = #line) {
        _ = ghosttyLinkAnchor
    }
}
