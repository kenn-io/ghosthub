import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("Workspace sidebar session actions")
struct WorkspaceSidebarViewTests {
    @Test("section actions target their exact host")
    func sectionActionsTargetExactHost() throws {
        let host = HostSummary.fixture(
            id: UUID(),
            herdrAvailable: true,
            zellijAvailable: true
        )
        var tmuxHosts: [UUID] = []
        var herdrHosts: [UUID] = []
        var zellijHosts: [UUID] = []
        var projectHosts: [UUID] = []
        let action = { section in
            WorkspaceSidebarSectionActionModel.action(
                for: section,
                host: host,
                onNewTmuxSession: { tmuxHosts.append($0.id) },
                onNewHerdrSession: { herdrHosts.append($0.id) },
                onNewZellijSession: { zellijHosts.append($0.id) },
                onAddProject: { projectHosts.append($0.id) }
            )
        }

        try #require(action(.tmuxSessions)).perform()
        try #require(action(.herdrSessions)).perform()
        try #require(action(.zellijSessions)).perform()
        try #require(action(.projects)).perform()
        #expect(tmuxHosts == [host.id])
        #expect(herdrHosts == [host.id])
        #expect(zellijHosts == [host.id])
        #expect(projectHosts == [host.id])
    }

    @Test("Herdr action follows availability rather than inventory")
    func herdrActionFollowsAvailability() {
        let availableHost = HostSummary.fixture(
            id: UUID(),
            herdrSessions: [],
            herdrAvailable: true
        )
        let unavailableHost = HostSummary.fixture(
            id: UUID(),
            name: "Without Herdr",
            kind: .remote,
            platform: .linux,
            herdrSessions: [],
            herdrAvailable: false
        )
        #expect(WorkspaceSidebarSectionActionModel.isVisible(
            .herdrSessions,
            host: availableHost,
            hasProjects: false
        ))
        #expect(!WorkspaceSidebarSectionActionModel.isVisible(
            .herdrSessions,
            host: unavailableHost,
            hasProjects: false
        ))
        #expect(WorkspaceSidebarSectionActionModel.action(
            for: .herdrSessions,
            host: unavailableHost,
            onNewTmuxSession: { _ in },
            onNewHerdrSession: { _ in },
            onNewZellijSession: { _ in },
            onAddProject: { _ in }
        ) == nil)
    }

    @Test("existing projects remain visible without registration")
    func existingProjectsRemainVisibleWithoutRegistration() {
        let host = HostSummary.fixture(
            kind: .remote,
            platform: .windows,
            remoteCapabilities: nil
        )

        #expect(!host.canRegisterProjects)
        #expect(WorkspaceSidebarSectionActionModel.isVisible(
            .projects,
            host: host,
            hasProjects: true
        ))
        #expect(WorkspaceSidebarSectionActionModel.action(
            for: .projects,
            host: host,
            onNewTmuxSession: { _ in },
            onNewHerdrSession: { _ in },
            onNewZellijSession: { _ in },
            onAddProject: { _ in }
        ) == nil)
    }

    @MainActor
    @Test("active Herdr row remains selected")
    func activeHerdrRowRemainsSelected() {
        let hostID = UUID()
        let row = WorkspaceSidebarRow(
            target: .herdrSession(hostID: hostID, name: "api"),
            icon: .herdrSession,
            title: "api",
            subtitle: "Herdr session"
        )
        let activeHerdrSession = WorkspaceHerdrSessionSelection(
            hostID: hostID,
            name: "api"
        )

        #expect(WorkspaceSidebarView.isRowSelected(
            row,
            selection: WorkspaceSelection(selectedHostID: hostID),
            activeTmuxSession: nil,
            activeHerdrSession: activeHerdrSession
        ))
    }

    @Test("Herdr rows expose lifecycle actions by state and identity")
    func herdrRowsExposeLifecycleActions() {
        let hostID = UUID()
        let snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(
                id: hostID,
                herdrSessions: [
                    .init(name: "api", isDefault: true, state: .running),
                    .init(name: "sleeping", isDefault: false, state: .stopped),
                    .init(name: "default", isDefault: true, state: .stopped),
                ]
            ),
        ])
        let rows = WorkspaceSidebarModel.sections(in: snapshot)[0]
            .herdrSessionRows

        #expect(WorkspaceSidebarRowActionModel.actions(
            for: rows.first(where: { $0.title == "api" })!,
            in: snapshot
        ) == [.stopHerdrSession(.init(hostID: hostID, name: "api"))])
        #expect(WorkspaceSidebarRowActionModel.actions(
            for: rows.first(where: { $0.title == "sleeping" })!,
            in: snapshot
        ) == [
            .restartHerdrSession(.init(hostID: hostID, name: "sleeping")),
            .deleteHerdrSession(.init(hostID: hostID, name: "sleeping")),
        ])
        #expect(WorkspaceSidebarRowActionModel.actions(
            for: rows.first(where: { $0.title == "default" })!,
            in: snapshot
        ) == [
            .restartHerdrSession(.init(hostID: hostID, name: "default")),
        ])
        #expect(WorkspaceSidebarRowActionModel.actions(
            for: rows.first(where: { $0.title == "api" })!,
            in: snapshot,
            pendingHerdrSessions: [.init(hostID: hostID, name: "api")]
        ).isEmpty)
    }
}
