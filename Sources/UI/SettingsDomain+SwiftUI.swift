import GhosthubSettings

extension SettingsDomain {
    var systemImageName: String {
        switch self {
        case .appearance:
            return "paintbrush"
        case .terminal:
            return "cursorarrow.motionlines"
        case .keyboard:
            return "keyboard"
        case .worktrees:
            return "arrow.triangle.branch"
        case .agents:
            return "bell.badge"
        case .privacy:
            return "hand.raised"
        case .hosts:
            return "desktopcomputer"
        }
    }
}
