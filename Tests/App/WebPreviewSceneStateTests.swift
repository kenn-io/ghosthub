import Foundation
import GhosthubPersistence
import GhosthubTestSupport
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@MainActor
@Suite("Web preview scene state")
struct WebPreviewSceneStateTests {
    @Test("a requested preview returns after a remote selection")
    func requestedPreviewReturnsAfterRemoteSelection() throws {
        let localHost = HostSummary.fixture(
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let remoteHost = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "build-box"
        )
        let localProject = ProjectSummary.fixture(hostID: localHost.id)
        let remoteProject = ProjectSummary.fixture(hostID: remoteHost.id)
        let localWorktree = WorktreeSummary.fixture(
            hostID: localHost.id,
            projectID: localProject.id,
            name: "local"
        )
        let remoteWorktree = WorktreeSummary.fixture(
            hostID: remoteHost.id,
            projectID: remoteProject.id,
            name: "remote"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [localHost, remoteHost],
            projects: [localProject, remoteProject],
            worktrees: [localWorktree, remoteWorktree]
        )
        let model = try makeModel(
            database: WorkspaceDatabase.inMemory(),
            localHostID: localHost.id,
            snapshot: snapshot
        )

        model.selection = selection(
            host: localHost,
            project: localProject,
            worktree: localWorktree
        )
        model.toggleWebPreview()
        #expect(model.isWebPreviewRequested)
        #expect(model.webPreviewContext?.worktreeID == localWorktree.id)

        model.selection = selection(
            host: remoteHost,
            project: remoteProject,
            worktree: remoteWorktree
        )
        #expect(model.isWebPreviewRequested)
        #expect(model.webPreviewContext == nil)

        model.selection = selection(
            host: localHost,
            project: localProject,
            worktree: localWorktree
        )
        #expect(model.isWebPreviewRequested)
        #expect(model.webPreviewContext?.worktreeID == localWorktree.id)
    }

    @Test("inventory removal releases its temporary browser session")
    func inventoryRemovalReleasesSession() throws {
        let environment = try setupStandardEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot
        )
        model.selection = WorkspaceSelection(
            selectedHostID: environment.host.id,
            selectedProjectID: environment.project.id,
            selectedWorktreeID: environment.worktree.id
        )
        let context = try #require(model.webPreviewContext)
        var session: WebPreviewSession? = model.webPreviewStore.session(
            for: context
        )
        weak let releasedSession = session

        session = nil
        model.snapshot = WorkspaceSnapshot(
            hosts: model.snapshot.hosts,
            projects: model.snapshot.projects,
            worktrees: []
        )

        #expect(releasedSession == nil)
    }

    private func selection(
        host: HostSummary,
        project: ProjectSummary,
        worktree: WorktreeSummary
    ) -> WorkspaceSelection {
        WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: worktree.id
        )
    }
}
