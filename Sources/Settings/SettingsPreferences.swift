import Foundation
import GhosthubWorkspace

public struct WorktreePreferences: Equatable, Sendable {
    public var hideRootCheckout: Bool
    public var showHiddenWorktreesByDefault: Bool

    public init(
        hideRootCheckout: Bool,
        showHiddenWorktreesByDefault: Bool
    ) {
        self.hideRootCheckout = hideRootCheckout
        self.showHiddenWorktreesByDefault = showHiddenWorktreesByDefault
    }
}

public struct AgentPreferences: Equatable, Sendable {
    public init() {}
}
