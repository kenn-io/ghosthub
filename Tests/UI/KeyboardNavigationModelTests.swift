import Foundation
import GhosthubTestSupport
import Testing
import GhosthubWorkspace
@testable import GhosthubUI

struct KeyboardNavigationModelTests {
    @Test("worktree siblings stay inside one repository and wrap")
    func worktreeSiblingsAreRepositoryLocal() throws {
        let bootstrap = WorkspaceBootstrap.preview()
        let sections = WorkspaceSidebarModel.sections(
            in: bootstrap.snapshot
        )
        let project = try #require(
            sections.flatMap(\.projects).first { $0.worktrees.count >= 2 }
        )
        let context = KeyboardNavigationContext(
            snapshot: bootstrap.snapshot
        )
        let first = try #require(project.worktreeRows.first?.target)
        let last = try #require(project.worktreeRows.last?.target)

        #expect(
            KeyboardNavigationModel.siblingTargets(
                for: first,
                in: context
            ) == project.worktreeRows.map(\.target)
        )
        #expect(KeyboardNavigationModel.steppedTarget(
            from: last,
            step: 1,
            in: context
        ) == first)
        #expect(KeyboardNavigationModel.steppedTarget(
            from: first,
            step: -1,
            in: context
        ) == last)
    }

    @Test("session sibling groups are host-local and filter eligibility")
    func hostSessionSiblingGroups() {
        let hostID = UUID()
        let directoryOne = DirectoryWorkspaceSummary(
            id: UUID(), hostID: hostID, name: "one", path: "/tmp/one",
            tmuxSessionName: "dir-one", sessionLive: true
        )
        let directoryTwo = DirectoryWorkspaceSummary(
            id: UUID(), hostID: hostID, name: "two", path: "/tmp/two",
            tmuxSessionName: "dir-two", sessionLive: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(
                id: hostID,
                tmuxSessions: [
                    .init(name: "alpha", managed: false, windows: []),
                    .init(name: "hidden", managed: false, windows: []),
                    .init(name: "omega", managed: false, windows: []),
                ],
                herdrSessions: [
                    .init(name: "running-a", isDefault: false, state: .running),
                    .init(name: "stopped", isDefault: false, state: .stopped),
                    .init(name: "running-z", isDefault: false, state: .running),
                ]
            )], projects: [], worktrees: [],
            directoryWorkspaces: [directoryOne, directoryTwo]
        )
        let context = KeyboardNavigationContext(
            snapshot: snapshot,
            tmuxSessionVisibility: .init(hiddenPatterns: ["hidden"])
        )

        #expect(KeyboardNavigationModel.siblingTargets(
            for: .directoryWorkspace(directoryOne.id), in: context
        ) == [
            .directoryWorkspace(directoryOne.id),
            .directoryWorkspace(directoryTwo.id),
        ])
        #expect(KeyboardNavigationModel.siblingTargets(
            for: .tmuxSession(hostID: hostID, name: "alpha"), in: context
        ) == [
            .tmuxSession(hostID: hostID, name: "alpha"),
            .tmuxSession(hostID: hostID, name: "omega"),
        ])
        #expect(KeyboardNavigationModel.siblingTargets(
            for: .herdrSession(hostID: hostID, name: "running-a"), in: context
        ) == [
            .herdrSession(hostID: hostID, name: "running-a"),
            .herdrSession(hostID: hostID, name: "running-z"),
        ])
        #expect(KeyboardNavigationModel.siblingTargets(
            for: .herdrSession(hostID: hostID, name: "stopped"), in: context
        ).isEmpty)
    }

    @Test("single, missing, and non-session targets pass through")
    func unavailableTargetsPassThrough() {
        let snapshot = WorkspaceSnapshot.fixture(hosts: [.fixture()])
        let context = KeyboardNavigationContext(snapshot: snapshot)

        #expect(KeyboardNavigationModel.steppedTarget(
            from: .host(snapshot.hosts[0].id), step: 1, in: context
        ) == nil)
        #expect(KeyboardNavigationModel.targetForShortcutIndex(
            1,
            from: .tmuxSession(
                hostID: snapshot.hosts[0].id,
                name: "missing"
            ),
            in: context
        ) == nil)
    }

}
