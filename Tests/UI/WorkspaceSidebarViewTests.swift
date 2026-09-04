import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubUI

@Suite("Workspace sidebar session actions")
struct WorkspaceSidebarViewTests {
    @Test("tmux preview disclosure requires mode and retained identity")
    func tmuxPreviewDisclosureEligibility() {
        let sessionID = "host:default:opened"

        #expect(!TmuxSessionPreviewRowPresentation.canDisclose(
            mode: .off,
            sessionID: sessionID,
            previewableSessionIDs: [sessionID]
        ))
        #expect(TmuxSessionPreviewRowPresentation.canDisclose(
            mode: .efficient,
            sessionID: sessionID,
            previewableSessionIDs: [sessionID]
        ))
        #expect(!TmuxSessionPreviewRowPresentation.canDisclose(
            mode: .live,
            sessionID: sessionID,
            previewableSessionIDs: []
        ))
    }

    @Test("Off hides previews without discarding scene expansion")
    func tmuxPreviewExpansionSurvivesOff() {
        let sessionID = "host:default:opened"
        var state = TmuxSessionPreviewExpansionState()
        state.setExpanded(true, sessionID: sessionID)

        #expect(state.isExpanded(sessionID))
        #expect(!TmuxSessionPreviewRowPresentation.isVisible(
            mode: .off,
            sessionID: sessionID,
            previewableSessionIDs: [sessionID],
            expansion: state
        ))
        #expect(TmuxSessionPreviewRowPresentation.isVisible(
            mode: .live,
            sessionID: sessionID,
            previewableSessionIDs: [sessionID],
            expansion: state
        ))
    }

    @Test("Always Live expands by default and honors a collapsed override")
    func alwaysLivePreviewCanCollapse() {
        let sessionID = "host:default:opened"
        var state = TmuxSessionPreviewExpansionState()

        #expect(TmuxSessionPreviewRowPresentation.isExpanded(
            mode: .alwaysLive,
            sessionID: sessionID,
            expansion: state
        ))

        state.setExpanded(
            false,
            sessionID: sessionID,
            defaultExpanded: true
        )

        #expect(!TmuxSessionPreviewRowPresentation.isExpanded(
            mode: .alwaysLive,
            sessionID: sessionID,
            expansion: state
        ))
        #expect(!state.isExpanded(sessionID))
    }

    @MainActor
    @Test("duplicate preview mounts release after their last ancestor collapses")
    func duplicatePreviewMountsReleaseAfterLastAncestorCollapse() {
        let hostID = UUID()
        let session = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "opened"
        )
        var mountState = TmuxSessionPreviewMountState()
        var mountedStates: [Bool] = []
        let onMountChanged: (
            WorkspaceTmuxSessionSelection,
            UUID,
            Bool
        ) -> Void = { session, mountID, mounted in
            if let expanded = mountState.setMounted(
                mounted,
                sessionID: session.id,
                mountID: mountID
            ) {
                mountedStates.append(expanded)
            }
        }
        let firstPreview = AnyView(
            Color.clear
                .frame(height: 40)
                .modifier(TmuxSessionPreviewMountModifier(
                    session: session,
                    onMountChanged: onMountChanged
                ))
        )
        let secondPreview = AnyView(
            Color.clear
                .frame(height: 40)
                .modifier(TmuxSessionPreviewMountModifier(
                    session: session,
                    onMountChanged: onMountChanged
                ))
        )
        let firstHostingView = hostView(firstPreview)
        let secondHostingView = hostView(secondPreview)

        #expect(mountedStates == [true])

        firstHostingView.rootView = AnyView(EmptyView())
        firstHostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(mountedStates == [true])

        secondHostingView.rootView = AnyView(EmptyView())
        secondHostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(mountedStates == [true, false])
    }

    @MainActor
    @Test("tmux activation carries its post-click route")
    func tmuxActivationCarriesPostClickRoute() {
        let hostID = UUID()
        let project = ProjectSummary.fixture(hostID: hostID)
        let worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id
        )
        let session = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "opened"
        )
        let snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(
                id: hostID,
                tmuxSessions: [
                    .init(name: session.name, managed: false, windows: []),
                ]
            ),
        ], projects: [project], worktrees: [worktree])
        var selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: project.id,
            selectedWorktreeID: worktree.id
        )
        var opened: [WorkspaceTmuxSessionSelection] = []
        var activationRoutes: [WorkspaceSelection] = []
        let selectionBinding = Binding(
            get: { selection },
            set: { selection = $0 }
        )

        WorkspaceSidebarView.activateTmuxSession(
            session,
            rowTarget: .tmuxSession(hostID: hostID, name: session.name),
            selection: selectionBinding,
            snapshot: snapshot,
            visibility: .default,
            onOpen: { openedSession, route in
                opened.append(openedSession)
                activationRoutes.append(route)
            }
        )

        #expect(opened == [session])
        #expect(activationRoutes == [selection])
        #expect(selection.selectedHostID == hostID)
        #expect(selection.selectedProjectID == nil)
        #expect(selection.selectedWorktreeID == nil)
    }

    @MainActor
    @Test("tmux activation commits its route before opening")
    func tmuxActivationCommitsRouteBeforeOpening() {
        let hostID = UUID()
        let session = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "opened"
        )
        let snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(
                id: hostID,
                tmuxSessions: [
                    .init(name: session.name, managed: false, windows: []),
                ]
            ),
        ])
        var storedSelection = WorkspaceSelection(selectedHostID: hostID)
        var events: [String] = []
        let selection = Binding(
            get: { storedSelection },
            set: {
                storedSelection = $0
                events.append("selected")
            }
        )

        WorkspaceSidebarView.activateTmuxSession(
            session,
            rowTarget: .tmuxSession(hostID: hostID, name: session.name),
            selection: selection,
            snapshot: snapshot,
            visibility: .default,
            onOpen: { _, _ in events.append("opened") }
        )

        #expect(events == ["selected", "opened"])
    }

    @MainActor
    @Test("window count stays as compact as the fallback running glyph")
    func windowCountIndicatorHeight() {
        let worktree = WorktreeSummary.fixture()
        let fallback = WorktreeRowStatus.make(
            for: worktree,
            sessions: [],
            hasLiveTmuxSession: true
        )
        let counted = WorktreeRowStatus.make(
            for: worktree,
            sessions: [],
            hasLiveTmuxSession: true,
            tmuxWindowCount: 3
        )
        let fallbackHeight = hostView(
            WorktreeRowLine(title: "main", status: fallback),
            size: CGSize(width: 180, height: 32)
        ).fittingSize.height
        let countedHeight = hostView(
            WorktreeRowLine(title: "main", status: counted),
            size: CGSize(width: 180, height: 32)
        ).fittingSize.height

        #expect(ceil(countedHeight) == ceil(fallbackHeight))
    }

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

    @MainActor
    @Test("a direct worktree row matches its active unbound endpoint")
    func directWorktreeRowMatchesActiveUnboundEndpoint() {
        let hostID = UUID()
        let worktreeID = UUID()
        let row = WorkspaceSidebarRow(
            target: .worktree(worktreeID),
            icon: .worktree,
            title: "Feature"
        )
        let worktree = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "kwt-project-feature",
            worktreeID: worktreeID,
            workspacePath: "/repo/feature",
            tmuxAttachMode: .direct
        )
        let active = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "kwt-project-feature"
        )

        #expect(WorkspaceSidebarView.isRowSelected(
            row,
            selection: WorkspaceSelection(selectedHostID: hostID),
            rowTmuxSession: worktree,
            activeTmuxSession: active,
            activeHerdrSession: nil
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
