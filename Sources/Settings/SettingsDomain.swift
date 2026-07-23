import Foundation

public enum SettingsDomain: String, CaseIterable, Identifiable, Sendable {
    case appearance
    case terminal
    case keyboard
    case worktrees
    case agents
    case hosts

    public var id: Self { self }

    public var title: String {
        switch self {
        case .appearance:
            return "Appearance"
        case .terminal:
            return "Terminal"
        case .keyboard:
            return "Keyboard"
        case .worktrees:
            return "Worktrees"
        case .agents:
            return "Agents"
        case .hosts:
            return "Hosts"
        }
    }

    public var subtitle: String {
        switch self {
        case .appearance:
            return "App chrome, built-in terminal themes,"
                + " font overrides, and cursor styling."
        case .terminal:
            return "Terminal interaction and ghostty.conf configuration."
        case .keyboard:
            return "Application and workspace navigation shortcuts."
        case .worktrees:
            return "Kwt workspace visibility and sidebar behavior."
        case .agents:
            return "Attention notifications for active agent sessions."
        case .hosts:
            return "Connect the machines and tmux sessions"
                + " in your tailnet or SSH network."
        }
    }
}
