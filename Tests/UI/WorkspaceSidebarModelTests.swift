import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

struct WorkspaceSidebarModelTests {
    @Test("project actions prefer the selected creatable project on their host")
    func prefersSelectedCreatableProject() {
        let hostID = UUID()
        let first = ProjectSummary.fixture(
            hostID: hostID,
            name: "agentsview"
        )
        let selected = ProjectSummary.fixture(
            hostID: hostID,
            name: "ghosthub"
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [first, selected]
        )
        let section = WorkspaceSidebarModel.sections(in: snapshot)[0]

        #expect(
            WorkspaceSidebarModel.preferredCreatableProject(
                in: section,
                snapshot: snapshot,
                selectedProjectID: selected.id
            )?.id == selected.id
        )
    }

    @Test("project actions stay host-scoped and require kwt availability")
    func scopesProjectActionsToCreatableHost() {
        let localID = UUID()
        let remoteID = UUID()
        let localProject = ProjectSummary.fixture(
            hostID: localID,
            name: "ghosthub"
        )
        let remoteProject = ProjectSummary.fixture(
            hostID: remoteID,
            name: "docbank"
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(id: localID),
                .fixture(
                    id: remoteID,
                    name: "Build Box",
                    kind: .remote,
                    sshDestination: "wesm@build-box",
                    operationAvailability: [
                        "worktreeCreate": OperationAvailabilityEntry(
                            available: false,
                            unavailableReason: "kwt is unavailable"
                        ),
                    ]
                ),
            ],
            projects: [localProject, remoteProject]
        )
        let sections = WorkspaceSidebarModel.sections(in: snapshot)

        #expect(
            WorkspaceSidebarModel.preferredCreatableProject(
                in: sections[0],
                snapshot: snapshot,
                selectedProjectID: remoteProject.id
            )?.id == localProject.id
        )
        #expect(
            WorkspaceSidebarModel.preferredCreatableProject(
                in: sections[1],
                snapshot: snapshot,
                selectedProjectID: localProject.id
            ) == nil
        )
    }

    @Test("hosts remain visible before they have projects or tmux sessions")
    func exposesEmptyHosts() {
        let local = HostSummary.fixture(name: "This Mac")
        let remote = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            sshDestination: "wesm@build-box"
        )

        let sections = WorkspaceSidebarModel.sections(
            in: .fixture(hosts: [local, remote])
        )

        #expect(sections.map(\.host.id) == [local.id, remote.id])
        #expect(sections.allSatisfy { $0.projects.isEmpty })
        #expect(sections.allSatisfy { $0.tmuxSessionRows.isEmpty })
    }

    @Test("sidebar disclosure defaults expose fleet before project contents")
    func sidebarDisclosureStateRoundTrips() {
        let hostID = UUID()
        let projectID = UUID()
        let hostKey = WorkspaceSidebarDisclosureState.host(hostID)
        let sessionsKey = WorkspaceSidebarDisclosureState.sessions(hostID)
        let projectsKey = WorkspaceSidebarDisclosureState.projects(hostID)
        let projectKey = WorkspaceSidebarDisclosureState.project(projectID)
        var state = WorkspaceSidebarDisclosureState()

        #expect(state.isExpanded(hostKey))
        #expect(state.isExpanded(sessionsKey))
        #expect(!state.isExpanded(projectsKey))
        #expect(!state.isExpanded(projectKey))

        state.toggle(projectsKey)
        state.toggle(projectKey)
        let restored = WorkspaceSidebarDisclosureState(
            rawValue: state.rawValue
        )
        #expect(restored.isExpanded(hostKey))
        #expect(restored.isExpanded(projectsKey))
        #expect(restored.isExpanded(projectKey))

        var reopened = restored
        reopened.toggle(projectKey)
        #expect(!reopened.isExpanded(projectKey))
        reopened.toggle(projectsKey)
        #expect(!reopened.isExpanded(projectsKey))
        #expect(reopened.rawValue.isEmpty)
    }

    @Test("legacy collapsed sidebar items migrate into disclosure overrides")
    func sidebarDisclosureStateMigratesLegacyKey() {
        let hostKey = WorkspaceSidebarDisclosureState.host(UUID())
        let sessionKey = WorkspaceSidebarDisclosureState.sessions(UUID())
        let legacy = [hostKey, sessionKey].joined(separator: "\n")

        let migrated = WorkspaceSidebarDisclosureState.migratedRawValue(
            current: "",
            legacyCollapsedKeys: legacy
        )
        let state = WorkspaceSidebarDisclosureState(rawValue: migrated)

        #expect(!state.isExpanded(hostKey))
        #expect(!state.isExpanded(sessionKey))
        #expect(migrated.contains("-\(hostKey)"))
        #expect(
            WorkspaceSidebarDisclosureState.migratedRawValue(
                current: "+\(hostKey)",
                legacyCollapsedKeys: legacy
            ) == "+\(hostKey)"
        )
    }

    @Test("selected kwt worktree resolves directly to its native tmux session")
    func resolvesSelectedWorktreeSession() {
        let hostID = UUID()
        let projectID = UUID()
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "main"
        )
        worktree.tmuxSessionName = "kwt-ghosthub-main"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [.fixture(id: projectID, hostID: hostID)],
            worktrees: [worktree]
        )
        let selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: projectID,
            selectedWorktreeID: worktree.id
        )

        #expect(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: selection,
                in: snapshot
            ) == WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "kwt-ghosthub-main",
                worktreeID: worktree.id,
                worktreePath: worktree.path
            )
        )
    }

    @Test("worktrees without a session never fall into implicit tmux attachment")
    func ignoresWorktreeWithoutSession() {
        let hostID = UUID()
        let projectID = UUID()
        let worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "main"
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [.fixture(id: projectID, hostID: hostID)],
            worktrees: [worktree]
        )

        #expect(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: WorkspaceSelection(
                    selectedHostID: hostID,
                    selectedProjectID: projectID,
                    selectedWorktreeID: worktree.id
                ),
                in: snapshot
            ) == nil
        )
    }

    @Test("hosts expose every discovered tmux session without requiring a project")
    func exposesHostTmuxSessions() {
        let hostID = UUID()
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(
                    id: hostID,
                    name: "Build Box",
                    kind: .remote,
                    sshDestination: "wesm@build-box",
                    tmuxSessions: [
                        TmuxSessionSummary(
                            name: "docbank",
                            managed: false,
                            windows: [
                                TmuxWindowSummary(
                                    id: "@1",
                                    index: 0,
                                    name: "editor"
                                ),
                            ]
                        ),
                        TmuxSessionSummary(
                            name: "kwt-workspace-core",
                            managed: true,
                            worktreeKey: "repo:/srv/core",
                            windows: []
                        ),
                    ]
                ),
            ]
        )

        let sections = WorkspaceSidebarModel.sections(in: snapshot)

        #expect(sections.count == 1)
        #expect(sections[0].projects.isEmpty)
        #expect(sections[0].tmuxSessionRows.map(\.title) == [
            "docbank", "kwt-workspace-core",
        ])
        #expect(sections[0].tmuxSessionRows[0].target == .tmuxSession(
            hostID: hostID,
            name: "docbank"
        ))
        #expect(sections[0].tmuxSessionRows[0].subtitle == "1 window")
        #expect(sections[0].tmuxSessionRows[0].icon == .tmuxSession)
        #expect(sections[0].tmuxSessionRows[0].indentLevel == 0)
        #expect(sections[0].tmuxSessionRows[1].subtitle == "Workspace session")
    }

    @Test("kwt workspace sessions appear only under their project")
    func filtersKwtSessionsFromGeneralSessions() {
        let hostID = UUID()
        let projectID = UUID()
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "main",
            path: "/code/docbank",
            branch: "main"
        )
        worktree.tmuxSessionName = "kwt-docbank-main"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(
                    id: hostID,
                    tmuxSessions: [
                        TmuxSessionSummary(
                            name: "kwt-docbank-main",
                            managed: false,
                            windows: []
                        ),
                        TmuxSessionSummary(
                            name: "external-agent",
                            managed: true,
                            windows: []
                        ),
                    ]
                ),
            ],
            projects: [
                .fixture(
                    id: projectID,
                    hostID: hostID,
                    name: "docbank",
                    rootPath: "/code/docbank"
                ),
            ],
            worktrees: [worktree]
        )

        let sections = WorkspaceSidebarModel.sections(in: snapshot)

        #expect(sections[0].tmuxSessionRows.map(\.title) == ["external-agent"])
        #expect(sections[0].projects[0].worktrees.map(\.id) == [worktree.id])
    }

    @Test("sidebar model groups active projects and visible worktrees")
    func groupsProjectsAndWorktrees() {
        let hostID = UUID()
        let projectID = UUID()
        let hiddenID = UUID()
        let visible = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "feature",
            path: "/repo-feature",
            branch: "feature"
        )
        let hidden = WorktreeSummary.fixture(
            id: hiddenID,
            hostID: hostID,
            projectID: projectID,
            name: "hidden",
            path: "/repo-hidden",
            branch: "hidden",
            isHidden: true
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID, name: "This Mac")],
            projects: [
                .fixture(
                    id: projectID,
                    hostID: hostID,
                    name: "ghosthub",
                    rootPath: "/repo"
                ),
            ],
            worktrees: [visible, hidden]
        )

        let sections = WorkspaceSidebarModel.sections(
            in: snapshot,
            visibility: WorktreeVisibility(showHiddenWorktrees: false)
        )

        #expect(sections.count == 1)
        #expect(sections[0].host.id == hostID)
        #expect(
            sections[0].row
                == WorkspaceSidebarRow(
                    target: .host(hostID),
                    icon: .localHost,
                    title: "This Mac"
                )
        )
        #expect(sections[0].projects.map(\.project.id) == [projectID])
        #expect(
            sections[0].projects[0].row
                == WorkspaceSidebarRow(
                    target: .project(projectID),
                    icon: .project,
                    title: "ghosthub",
                    subtitle: "/repo"
                )
        )
        #expect(sections[0].projects[0].worktrees.map(\.id) == [visible.id])
        #expect(sections[0].projects[0].worktreeRows.count == 1)
        let visibleRow = sections[0].projects[0].worktreeRows[0]
        #expect(visibleRow.target == .worktree(visible.id))
        #expect(visibleRow.icon == .worktree)
        #expect(visibleRow.title == "feature")
        #expect(visibleRow.subtitle == nil)
        #expect(visibleRow.indentLevel == 1)
        #expect(visibleRow.worktreeStatus != nil)
    }

    @Test("stale projects and worktrees are excluded")
    func excludesStaleItems() {
        let hostID = UUID()
        let activeProjectID = UUID()
        let staleProjectID = UUID()
        let active = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: activeProjectID,
            name: "main",
            path: "/repo",
            branch: "main"
        )
        let stale = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: activeProjectID,
            name: "old",
            path: "/repo-old",
            branch: "old",
            isStale: true
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID, name: "This Mac")],
            projects: [
                .fixture(
                    id: activeProjectID,
                    hostID: hostID,
                    name: "active",
                    rootPath: "/repo"
                ),
                .fixture(
                    id: staleProjectID,
                    hostID: hostID,
                    name: "stale",
                    rootPath: "/stale",
                    isStale: true
                ),
            ],
            worktrees: [active, stale]
        )

        let sections = WorkspaceSidebarModel.sections(in: snapshot)

        #expect(sections[0].projects.map(\.project.id) == [activeProjectID])
        #expect(sections[0].projects[0].worktrees.map(\.id) == [active.id])
    }

    @Test("sidebar rows encode remote host and primary worktree presentation")
    func rowPresentationForRemoteHostAndPrimaryWorktree() {
        let hostID = UUID()
        let projectID = UUID()
        let primary = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "",
            path: "/srv/repo",
            branch: "main",
            isPrimary: true
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(
                    id: hostID,
                    name: "Build Box",
                    kind: .remote,
                    sshDestination: "builder"
                ),
            ],
            projects: [
                .fixture(
                    id: projectID,
                    hostID: hostID,
                    name: "",
                    rootPath: "/srv/repo"
                ),
            ],
            worktrees: [primary]
        )

        let section = WorkspaceSidebarModel.sections(in: snapshot)[0]

        #expect(
            section.row
                == WorkspaceSidebarRow(
                    target: .host(hostID),
                    icon: .remoteHost,
                    title: "Build Box",
                    subtitle: "builder"
                )
        )
        #expect(section.projects[0].row.title == "Untitled")
        #expect(section.projects[0].worktreeRows.count == 1)
        let primaryRow = section.projects[0].worktreeRows[0]
        #expect(primaryRow.target == .worktree(primary.id))
        #expect(primaryRow.icon == .primaryWorktree)
        #expect(primaryRow.title == "Untitled")
        #expect(primaryRow.subtitle == nil)
        #expect(primaryRow.indentLevel == 1)
        #expect(primaryRow.worktreeStatus != nil)
    }
}
