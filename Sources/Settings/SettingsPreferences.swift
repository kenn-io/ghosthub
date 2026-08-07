import Foundation
import GhosthubWorkspace

public struct WorktreePreferences: Equatable, Sendable {
    public var hideRootCheckout: Bool
    public var showHiddenWorktreesByDefault: Bool
    public var hideKwtManagedSessions: Bool

    public init(
        hideRootCheckout: Bool,
        showHiddenWorktreesByDefault: Bool,
        hideKwtManagedSessions: Bool
    ) {
        self.hideRootCheckout = hideRootCheckout
        self.showHiddenWorktreesByDefault = showHiddenWorktreesByDefault
        self.hideKwtManagedSessions = hideKwtManagedSessions
    }
}

public struct TmuxSessionPreferences: Equatable, Sendable {
    public var hiddenSessionPatterns: [String]

    public init(hiddenSessionPatterns: [String] = []) {
        self.hiddenSessionPatterns = hiddenSessionPatterns
    }
}

public struct AgentPreferences: Equatable, Sendable {
    public init() {}
}
