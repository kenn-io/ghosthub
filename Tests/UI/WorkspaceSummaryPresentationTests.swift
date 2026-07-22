import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubUI
@testable import GhosthubWorkspace

struct HostSummaryPresentationTests {
    @Test("sidebar presentation stays in UI")
    func hostSidebarPresentation() {
        let unnamed = HostSummary.fixture(name: "")
        #expect(unnamed.sidebarTitle == "Untitled")
        #expect(unnamed.sidebarSubtitle == nil)

        let remote = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "rpi5-ssd",
            preferredTransport: .mosh,
            lastKnownReachable: false,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
            remoteHostname: "rpi5-ssd.tail-scale.ts.net",
            version: "0.1.0"
        )
        #expect(remote.sidebarTitle == "Build Box")
        #expect(remote.sidebarSubtitle == "rpi5-ssd")
        #expect(remote.commandPaletteSubtitle == "rpi5-ssd · Linux")
        #expect(remote.searchKeywords.contains("rpi5-ssd"))
        #expect(remote.searchKeywords.contains("0.1.0"))
    }
}

struct ProjectSummaryPresentationTests {
    @Test("sidebar title falls back for unnamed projects")
    func sidebarTitleFallsBackForUnnamedProjects() {
        let project = ProjectSummary.fixture(name: "")

        #expect(project.sidebarTitle == "Untitled")
    }

    @Test("sidebar subtitle prefers platform repository name")
    func sidebarSubtitlePrefersPlatformRepositoryName() {
        let project = ProjectSummary.fixture(
            rootPath: "/Users/wesm/code/app",
            platformURL: "https://github.com/acme/app",
            platformCoverage: "active"
        )

        #expect(project.sidebarSubtitle == "acme/app")
    }

    @Test("sidebar subtitle falls back to root path")
    func sidebarSubtitleFallsBackToRootPath() {
        let project = ProjectSummary.fixture(
            rootPath: "/Users/wesm/code/app"
        )

        #expect(project.sidebarSubtitle == "/Users/wesm/code/app")
    }
}

struct WorktreeSummaryPresentationTests {
    @Test("sidebar title falls back for unnamed worktrees")
    func sidebarTitleFallsBackForUnnamedWorktrees() {
        let worktree = WorktreeSummary.fixture(name: "")

        #expect(worktree.sidebarTitle == "Untitled")
    }

    @Test("sidebar subtitle includes branch and linked pull request")
    func sidebarSubtitleIncludesBranchAndLinkedPullRequest() {
        let worktree = WorktreeSummary.fixture(
            branch: "feature/sidebar",
            linkedIssueNumbers: [17],
            linkedPullRequestNumber: 42
        )

        #expect(worktree.sidebarSubtitle == "feature/sidebar · #42")
    }

    @Test("sidebar subtitle falls back to linked issue")
    func sidebarSubtitleFallsBackToLinkedIssue() {
        let worktree = WorktreeSummary.fixture(
            branch: "feature/sidebar",
            linkedIssueNumbers: [17, 18]
        )

        #expect(worktree.sidebarSubtitle == "feature/sidebar · #17")
    }

    @Test("sidebar subtitle supports branch-only and issue-only worktrees")
    func sidebarSubtitleSupportsSingleParts() {
        #expect(
            WorktreeSummary.fixture(
                branch: "main"
            ).sidebarSubtitle == "main"
        )
        #expect(
            WorktreeSummary.fixture(
                branch: "",
                linkedIssueNumbers: [12]
            ).sidebarSubtitle == "#12"
        )
    }

    @Test("sidebar subtitle is empty without branch or links")
    func sidebarSubtitleIsEmptyWithoutBranchOrLinks() {
        #expect(
            WorktreeSummary.fixture(
                branch: ""
            ).sidebarSubtitle.isEmpty
        )
    }
}

struct WorkspaceKnownAgentPresentationTests {
    @Test(
        "known agent display names are UI presentation",
        arguments: [
            (WorkspaceKnownAgent.claude, "Claude"),
            (WorkspaceKnownAgent.codex, "Codex"),
            (WorkspaceKnownAgent.opencode, "OpenCode"),
            (WorkspaceKnownAgent.gemini, "Gemini"),
            (WorkspaceKnownAgent.copilot, "Copilot"),
        ]
    )
    func knownAgentDisplayNames(
        agent: WorkspaceKnownAgent,
        displayName: String
    ) {
        #expect(agent.displayName == displayName)
    }
}
