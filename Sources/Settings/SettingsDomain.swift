import Foundation

public enum SettingsDomain: String, CaseIterable, Identifiable, Sendable {
    case appearance
    case sidebar
    case terminal
    case keyboard
    case worktrees
    case agents
    case privacy
    case hosts
    case integrations

    public var id: Self { self }

    public var title: String {
        switch self {
        case .appearance:
            return "Appearance"
        case .sidebar:
            return "Sidebar"
        case .terminal:
            return "Terminal"
        case .keyboard:
            return "Keyboard"
        case .worktrees:
            return "Worktrees"
        case .agents:
            return "Agents"
        case .privacy:
            return "Privacy"
        case .hosts:
            return "Hosts"
        case .integrations:
            return "Integrations"
        }
    }

    public var subtitle: String {
        switch self {
        case .appearance:
            return "App chrome, built-in tmux themes,"
                + " font overrides, and cursor styling."
        case .sidebar:
            return "How hosts, sessions, and worktrees appear in the sidebar."
        case .terminal:
            return "Terminal interaction and ghostty.conf configuration."
        case .keyboard:
            return "Application and workspace navigation shortcuts."
        case .worktrees:
            return "Hidden tmux session patterns and workspace sessions."
        case .agents:
            return "Attention notifications for active agent sessions."
        case .privacy:
            return "Control anonymous usage reporting."
        case .hosts:
            return "Connect the machines and tmux sessions"
                + " in your tailnet or SSH network."
        case .integrations:
            return "Connect third-party services that contribute"
                + " hosts and other resources to Ghosthub."
        }
    }
}
