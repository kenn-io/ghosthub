import Foundation
import GhosthubTestSupport
@testable import GhosthubUI
import GhosthubWorkspace
import Testing

struct WorkspaceAccessibilityModelTests {
    let bootstrap: WorkspaceBootstrap
    let snapshot: WorkspaceSnapshot

    init() {
        bootstrap = .preview()
        snapshot = bootstrap.snapshot
    }

    @Test("command descriptors use shortcuts as accessibility values")
    func commandDescriptorUsesShortcutAsAccessibilityValue() throws {
        let command = CommandPaletteModel.commands(
            in: snapshot,
            selection: bootstrap.selection,
            isSidebarVisible: true,
            isSidePanelVisible: false
        ).first { $0.title == "Hide Sidebar" }

        expectAccessibilityDescriptor(
            WorkspaceAccessibilityModel.descriptor(
                for: try #require(command)
            ),
            label: "Hide Sidebar",
            value: "⌘B",
            hint: "Toggle the project and worktree navigation sidebar."
        )
    }

    @Test("sidebar session rows announce identity state and action")
    func sidebarSessionDescriptor() {
        let row = WorkspaceSidebarRow(
            target: .tmuxSession(hostID: UUID(), name: "docbank"),
            icon: .tmuxSession,
            title: "docbank",
            subtitle: "2 windows"
        )

        expectAccessibilityDescriptor(
            WorkspaceAccessibilityModel.descriptor(
                for: row,
                isSelected: true,
                hasRecentTmuxOutput: true
            ),
            label: "docbank",
            value: "2 windows, Recent tmux output, Selected",
            hint: "Attach to this tmux session."
        )
    }

    @Test("sidebar disclosures announce their target and state")
    func sidebarDisclosureDescriptor() {
        expectAccessibilityDescriptor(
            WorkspaceAccessibilityModel.disclosureDescriptor(
                title: "Projects",
                isExpanded: false
            ),
            label: "Expand Projects",
            value: "Collapsed",
            hint: "Show or hide the items in Projects."
        )
    }

    @Test("stopped Herdr rows announce state and restart behavior")
    func stoppedHerdrDescriptor() {
        let row = WorkspaceSidebarRow(
            target: .herdrSession(hostID: UUID(), name: "review"),
            icon: .herdrSession,
            title: "review",
            subtitle: "Stopped",
            herdrSessionState: .stopped,
            herdrSessionIsDefault: false
        )

        expectAccessibilityDescriptor(
            WorkspaceAccessibilityModel.descriptor(
                for: row,
                isSelected: false
            ),
            label: "review",
            value: "Stopped",
            hint: "Restart and attach to this Herdr session."
        )
    }

    @Test("worktree rows announce visible status and select-only behavior")
    func worktreeStatusDescriptor() {
        let row = WorkspaceSidebarRow(
            target: .worktree(UUID()),
            icon: .worktree,
            title: "release-work",
            worktreeStatus: WorktreeRowStatus(
                diffAdded: 1,
                diffRemoved: 8,
                syncAhead: 2,
                syncBehind: 1,
                isRunning: true,
                isAgentRunning: true,
                prNumber: 73,
                prTitle: "Make remote creation one-shot",
                isDraft: true,
                checks: .pending,
                showsSecondLine: true
            )
        )

        expectAccessibilityDescriptor(
            WorkspaceAccessibilityModel.descriptor(
                for: row,
                isSelected: true
            ),
            label: "release-work",
            value: "1 line added, 8 lines removed, 2 commits ahead, "
                + "1 commit behind, Agent running, Pull request #73, "
                + "Make remote creation one-shot, Draft, Checks pending, "
                + "Selected",
            hint: "Select this worktree."
        )
    }

    @Test("worktree rows announce tmux windows without redundant running text")
    func worktreeWindowCountDescriptor() {
        let row = WorkspaceSidebarRow(
            target: .worktree(UUID()),
            icon: .worktree,
            title: "release-work",
            worktreeStatus: WorktreeRowStatus(
                diffAdded: nil,
                diffRemoved: nil,
                syncAhead: nil,
                syncBehind: nil,
                tmuxWindowCount: 3,
                isRunning: true,
                isAgentRunning: true,
                prNumber: nil,
                prTitle: nil,
                isDraft: false,
                checks: nil,
                showsSecondLine: false
            )
        )

        expectAccessibilityDescriptor(
            WorkspaceAccessibilityModel.descriptor(
                for: row,
                isSelected: false
            ),
            label: "release-work",
            value: "3 windows, Agent running",
            hint: "Select this worktree."
        )
    }

}

private func expectAccessibilityDescriptor(
    _ descriptor: WorkspaceAccessibilityDescriptor,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    hintContains: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if let label {
        #expect(
            descriptor.label == label,
            sourceLocation: sourceLocation
        )
    }
    #expect(
        descriptor.value == value,
        sourceLocation: sourceLocation
    )
    if let hint {
        #expect(
            descriptor.hint == hint,
            sourceLocation: sourceLocation
        )
    }
    if let hintContains {
        #expect(
            descriptor.hint?.contains(hintContains) == true,
            sourceLocation: sourceLocation
        )
    }
}
