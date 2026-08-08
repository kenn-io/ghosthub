import Foundation
import GhosthubWorkspace

struct WorkspaceAccessibilityDescriptor: Equatable, Sendable {
    let label: String
    let value: String?
    let hint: String?

    init(
        label: String,
        value: String? = nil,
        hint: String? = nil
    ) {
        self.label = label
        self.value = value
        self.hint = hint
    }
}

enum WorkspaceAccessibilityModel {
    static func descriptor(for command: WorkspaceCommandItem)
        -> WorkspaceAccessibilityDescriptor {
        WorkspaceAccessibilityDescriptor(
            label: command.title,
            value: command.shortcut?.displayText,
            hint: command.subtitle
        )
    }

    static func commandPaletteSearchDescriptor() -> WorkspaceAccessibilityDescriptor {
        WorkspaceAccessibilityDescriptor(
            label: "Command Palette Search",
            hint: "Type to filter commands, hosts, projects, and worktrees."
        )
    }

    static func descriptor(
        for row: WorkspaceSidebarRow,
        isSelected: Bool,
        hasRecentTmuxOutput: Bool = false
    ) -> WorkspaceAccessibilityDescriptor {
        var values: [String] = []
        if let subtitle = row.subtitle, !subtitle.isEmpty {
            values.append(subtitle)
        }
        if let status = row.worktreeStatus {
            values.append(contentsOf: worktreeStatusValues(status))
        }
        if row.sessionIsRunning {
            values.append("Session running")
        }
        if hasRecentTmuxOutput {
            values.append("Recent tmux output")
        }
        if isSelected {
            values.append("Selected")
        }
        let hint: String
        switch row.target {
        case .host:
            hint = "Select this host."
        case .project:
            hint = "Select this project."
        case .worktree:
            hint = "Select this worktree."
        case .directoryWorkspace:
            hint = "Open this directory workspace."
        case .tmuxSession:
            hint = "Attach to this tmux session."
        case .herdrSession:
            hint = row.herdrSessionState == .stopped
                ? "Restart and attach to this Herdr session."
                : "Attach to this Herdr session."
        }
        return WorkspaceAccessibilityDescriptor(
            label: row.title,
            value: values.isEmpty ? nil : values.joined(separator: ", "),
            hint: hint
        )
    }

    private static func worktreeStatusValues(
        _ status: WorktreeRowStatus
    ) -> [String] {
        var values: [String] = []
        if let added = status.diffAdded {
            values.append("\(added) \(lineLabel(added)) added")
        }
        if let removed = status.diffRemoved {
            values.append("\(removed) \(lineLabel(removed)) removed")
        }
        if let ahead = status.syncAhead {
            values.append("\(ahead) \(commitLabel(ahead)) ahead")
        }
        if let behind = status.syncBehind {
            values.append("\(behind) \(commitLabel(behind)) behind")
        }
        if status.isRunning {
            values.append(
                status.isAgentRunning ? "Agent running" : "Session running"
            )
        }
        if status.showsSecondLine {
            if let number = status.prNumber {
                values.append("Pull request #\(number)")
            }
            if let title = status.prTitle, !title.isEmpty {
                values.append(title)
            }
            if status.isDraft {
                values.append("Draft")
            }
            if let checks = status.checks {
                switch checks {
                case .success:
                    values.append("Checks passed")
                case .failure:
                    values.append("Checks failed")
                case .pending:
                    values.append("Checks pending")
                }
            }
        }
        return values
    }

    private static func lineLabel(_ count: Int) -> String {
        count == 1 ? "line" : "lines"
    }

    private static func commitLabel(_ count: Int) -> String {
        count == 1 ? "commit" : "commits"
    }

    static func disclosureDescriptor(
        title: String,
        isExpanded: Bool
    ) -> WorkspaceAccessibilityDescriptor {
        WorkspaceAccessibilityDescriptor(
            label: "\(isExpanded ? "Collapse" : "Expand") \(title)",
            value: isExpanded ? "Expanded" : "Collapsed",
            hint: "Show or hide the items in \(title)."
        )
    }
}
