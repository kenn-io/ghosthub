import Foundation
import GhosthubPersistence
import GhosthubTerminalSupport
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Workspace application shortcuts", .serialized)
@MainActor
struct WorkspaceApplicationShortcutTests {
    @Test("sibling availability requires a resolvable peer")
    func siblingAvailability() async throws {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let only = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "only"
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [project], worktrees: [only]
            )
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: only.id
        )

        #expect(!model.canPerformSiblingShortcut(.nextSibling))

        model.snapshot.worktrees.append(WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "peer"
        ))
        #expect(model.canPerformSiblingShortcut(.nextSibling))
        #expect(model.canPerformSiblingShortcut(.selectSibling2))
        #expect(!model.canPerformSiblingShortcut(.selectSibling3))
        await model.shutdown()
    }

    @Test("focused sibling navigation selects within the current project")
    func focusedSiblingNavigation() async throws {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let first = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "first"
        )
        let second = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "second"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host], projects: [project],
            worktrees: [first, second]
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: snapshot
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: first.id
        )

        #expect(!model.performApplicationShortcut(.nextSibling))
        model.isFocusedWindow = true
        #expect(model.performApplicationShortcut(.nextSibling))
        #expect(model.selection.selectedWorktreeID == second.id)
        #expect(model.performApplicationShortcut(.previousSibling))
        #expect(model.selection.selectedWorktreeID == first.id)
        await model.shutdown()
    }

    @Test("menu sibling navigation uses its captured scene")
    func menuSiblingNavigation() async throws {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let first = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "first"
        )
        let second = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "second"
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [project],
                worktrees: [first, second]
            )
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: first.id
        )
        model.isFocusedWindow = false

        #expect(model.performApplicationShortcut(
            .nextSibling,
            invocation: .menu
        ))
        #expect(model.selection.selectedWorktreeID == second.id)
        await model.shutdown()
    }

    @Test("pull request import does not require worktree creation")
    func pullRequestImportWithoutCreation() async throws {
        let host = HostSummary.fixture(operationAvailability: [
            "worktreeCreate": .init(available: false),
            "pullRequestImport": .init(available: true),
        ])
        let project = ProjectSummary(
            id: UUID(),
            hostID: host.id,
            scopedKey: "github.com/example/project-a",
            name: "project-a",
            rootPath: "/tmp/project-a"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host], projects: [project], worktrees: []
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: snapshot
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id
        )
        model.isFocusedWindow = true

        #expect(!snapshot.canCreateWorktree(in: project))
        #expect(snapshot.canImportPullRequest(in: project))
        #expect(model.performApplicationShortcut(.importPullRequest))
        await model.shutdown()
    }

    @Test("presentation actions report availability and mutate once")
    func presentationActions() async throws {
        let environment = try setupHostEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot
        )
        model.isFocusedWindow = true

        #expect(model.performApplicationShortcut(.commandPalette))
        #expect(model.isCommandPalettePresented)
        #expect(model.performApplicationShortcut(.openApplicationLog))
        #expect(model.isLogViewerPresented)
        #expect(!model.performApplicationShortcut(.splitRight))
        #expect(!model.performApplicationShortcut(.newHerdrSession))
        await model.shutdown()
    }
}
