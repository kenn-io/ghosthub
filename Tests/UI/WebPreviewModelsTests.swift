import Foundation
import GhosthubTestSupport
@testable import GhosthubUI
import GhosthubWorkspace
import Testing

@Suite("Web preview eligibility")
struct WebPreviewEligibilityTests {
    @Test("only a selected, current local worktree is eligible")
    func selectedCurrentLocalWorktreeIsEligible() throws {
        let localHost = HostSummary.fixture(
            configKey: "local-mac",
            kind: .selfHost
        )
        let remoteHost = HostSummary.fixture(
            configKey: "build-box",
            kind: .remote
        )
        let localProject = ProjectSummary.fixture(hostID: localHost.id)
        let remoteProject = ProjectSummary.fixture(hostID: remoteHost.id)
        let localWorktree = WorktreeSummary.fixture(
            hostID: localHost.id,
            projectID: localProject.id,
            scopedKey: "worktree:/src/ghosthub",
            name: "preview"
        )
        let staleWorktree = WorktreeSummary.fixture(
            hostID: localHost.id,
            projectID: localProject.id,
            scopedKey: "worktree:/src/ghosthub-stale",
            isStale: true
        )
        let remoteWorktree = WorktreeSummary.fixture(
            hostID: remoteHost.id,
            projectID: remoteProject.id,
            scopedKey: "worktree:/srv/ghosthub"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [localHost, remoteHost],
            projects: [localProject, remoteProject],
            worktrees: [localWorktree, staleWorktree, remoteWorktree]
        )

        let context = try #require(
            WebPreviewEligibility.context(
                in: snapshot,
                selection: WorkspaceSelection(
                    selectedHostID: localHost.id,
                    selectedProjectID: localProject.id,
                    selectedWorktreeID: localWorktree.id
                )
            )
        )
        #expect(context.worktreeID == localWorktree.id)
        #expect(context.worktreeName == "preview")

        #expect(
            WebPreviewEligibility.context(
                in: snapshot,
                selection: WorkspaceSelection(
                    selectedHostID: remoteHost.id,
                    selectedProjectID: remoteProject.id,
                    selectedWorktreeID: remoteWorktree.id
                )
            ) == nil
        )
        #expect(
            WebPreviewEligibility.context(
                in: snapshot,
                selection: WorkspaceSelection(
                    selectedHostID: localHost.id,
                    selectedProjectID: localProject.id,
                    selectedWorktreeID: staleWorktree.id
                )
            ) == nil
        )
        #expect(
            WebPreviewEligibility.context(
                in: snapshot,
                selection: WorkspaceSelection(
                    selectedHostID: localHost.id,
                    selectedProjectID: localProject.id
                )
            ) == nil
        )
    }

    @Test("selection and worktree host must agree")
    func mismatchedSelectionIsIneligible() {
        let localHost = HostSummary.fixture(kind: .selfHost)
        let remoteHost = HostSummary.fixture(kind: .remote)
        let project = ProjectSummary.fixture(hostID: localHost.id)
        let worktree = WorktreeSummary.fixture(
            hostID: localHost.id,
            projectID: project.id
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [localHost, remoteHost],
            projects: [project],
            worktrees: [worktree]
        )

        #expect(
            WebPreviewEligibility.context(
                in: snapshot,
                selection: WorkspaceSelection(
                    selectedHostID: remoteHost.id,
                    selectedProjectID: project.id,
                    selectedWorktreeID: worktree.id
                )
            ) == nil
        )
    }
}

@Suite("Web preview addresses")
struct WebPreviewAddressTests {
    @Test("explicit HTTP and HTTPS addresses are accepted")
    func acceptsSupportedAddresses() throws {
        #expect(
            try WebPreviewAddress.parse(" http://localhost:3000 ")
                == URL(string: "http://localhost:3000")!
        )
        #expect(
            try WebPreviewAddress.parse("https://example.com/path?q=1")
                == URL(string: "https://example.com/path?q=1")!
        )
    }

    @Test(
        "unsupported or implicit addresses are rejected",
        arguments: [
            "",
            "localhost:3000",
            "file:///tmp/index.html",
            "javascript:alert(1)",
            "https:///missing-host",
        ]
    )
    func rejectsUnsupportedAddresses(_ address: String) {
        #expect(throws: WebPreviewAddressError.self) {
            try WebPreviewAddress.parse(address)
        }
    }
}

@Suite("Web preview layout policy")
struct WebPreviewLayoutPolicyTests {
    @Test("availability and requested visibility select the presentation mode")
    func resolvesPresentationMode() {
        #expect(
            WebPreviewLayoutPolicy.mode(
                windowWidth: 1_300,
                sidebarWidth: 320,
                isSidebarVisible: true,
                isPreviewAvailable: true,
                isPreviewRequested: true
            ) == .split
        )
        #expect(
            WebPreviewLayoutPolicy.mode(
                windowWidth: 760,
                sidebarWidth: 320,
                isSidebarVisible: true,
                isPreviewAvailable: true,
                isPreviewRequested: true
            ) == .previewOnly
        )
        #expect(
            WebPreviewLayoutPolicy.mode(
                windowWidth: 1_300,
                sidebarWidth: 320,
                isSidebarVisible: true,
                isPreviewAvailable: true,
                isPreviewRequested: false
            ) == .terminalOnly
        )
        #expect(
            WebPreviewLayoutPolicy.mode(
                windowWidth: 1_300,
                sidebarWidth: 320,
                isSidebarVisible: true,
                isPreviewAvailable: false,
                isPreviewRequested: true
            ) == .terminalOnly
        )
    }

    @Test("preview width leaves the terminal usable")
    func clampsPreviewWidth() {
        #expect(
            WebPreviewLayoutPolicy.clampedPreviewWidth(
                900,
                availableWidth: 1_000
            ) == 579
        )
        #expect(
            WebPreviewLayoutPolicy.clampedPreviewWidth(
                100,
                availableWidth: 1_500
            ) == 360
        )
        #expect(
            WebPreviewLayoutPolicy.clampedPreviewWidth(
                900,
                availableWidth: 1_500
            ) == 760
        )
    }
}
