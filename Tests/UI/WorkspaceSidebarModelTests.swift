import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

struct WorkspaceSidebarModelTests {
    @Test("drag ordering is durable and scoped to one project")
    func worktreeDragOrdering() {
        let first = WorktreeSummary.fixture(name: "first")
        let second = WorktreeSummary.fixture(name: "second")
        let third = WorktreeSummary.fixture(name: "third")
        let otherProject = WorktreeSummary.fixture(name: "other")
        var order = WorkspaceSidebarOrder()

        let didMove = order.move(
            first.id.uuidString,
            to: third.id.uuidString,
            within: [first, second, third].map { $0.id.uuidString }
        )
        #expect(didMove)
        #expect(order.ordered(
            [first, second, third],
            identifiedBy: { $0.id.uuidString }
        ).map(\.id)
            == [second.id, third.id, first.id])

        let restored = WorkspaceSidebarOrder(rawValue: order.rawValue)
        #expect(restored.ordered(
            [first, second, third],
            identifiedBy: { $0.id.uuidString }
        ).map(\.id)
            == [second.id, third.id, first.id])
        #expect(restored.ordered(
            [otherProject],
            identifiedBy: { $0.id.uuidString }
        ).map(\.id)
            == [otherProject.id])
    }

    @Test("drag ordering preserves omitted siblings in their stored slots")
    func dragOrderingPreservesOmittedSiblings() {
        var order = WorkspaceSidebarOrder(rawValue: "first\nsecond\nthird")

        let didMove = order.move(
            "first",
            to: "third",
            within: ["first", "third"]
        )

        #expect(didMove)
        #expect(order.rawValue == "third\nsecond\nfirst")
    }

    @Test("drop placement matches the final directional insertion")
    func dropPlacement() {
        let orderedIDs = ["first", "second", "third"]

        #expect(WorkspaceSidebarDropPlacement.resolve(
            sourceID: "first",
            targetID: "third",
            orderedIDs: orderedIDs
        ) == .after)
        #expect(WorkspaceSidebarDropPlacement.resolve(
            sourceID: "third",
            targetID: "first",
            orderedIDs: orderedIDs
        ) == .before)
        #expect(WorkspaceSidebarDropPlacement.resolve(
            sourceID: "second",
            targetID: "second",
            orderedIDs: orderedIDs
        ) == nil)
    }

    @Test("tmux session order persists independently for each host")
    func tmuxSessionOrdering() {
        let firstHostID = UUID()
        let secondHostID = UUID()
        let sessionNames = ["alpha", "beta", "gamma"]
        let firstHostIDs = sessionNames.map {
            WorkspaceSidebarModel.tmuxSessionOrderID(
                hostID: firstHostID,
                name: $0
            )
        }
        var order = WorkspaceSidebarOrder()
        let didMove = order.move(
            firstHostIDs[0],
            to: firstHostIDs[2],
            within: firstHostIDs
        )
        #expect(didMove)

        let snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(
                id: firstHostID,
                tmuxSessions: sessionNames.reversed().map {
                    TmuxSessionSummary(
                        name: $0,
                        managed: false,
                        windows: []
                    )
                }
            ),
            .fixture(
                id: secondHostID,
                kind: .remote,
                tmuxSessions: sessionNames.reversed().map {
                    TmuxSessionSummary(
                        name: $0,
                        managed: false,
                        windows: []
                    )
                }
            ),
        ])
        let sections = WorkspaceSidebarModel.sections(
            in: snapshot,
            tmuxSessionOrderRawValue: order.rawValue
        )

        #expect(sections[0].tmuxSessionRows.map(\.title)
            == ["beta", "gamma", "alpha"])
        #expect(sections[1].tmuxSessionRows.map(\.title)
            == ["alpha", "beta", "gamma"])
    }

    @Test("sidebar hierarchy advances one compact indent per level")
    func hierarchyIndentAdvancesByLevel() {
        let host = WorkspaceSidebarHierarchy.indent(level: 0)
        let child = WorkspaceSidebarHierarchy.indent(level: 1)
        let nested = WorkspaceSidebarHierarchy.indent(level: 2)

        #expect(host == 0)
        #expect(child > host)
        #expect(nested > child)
        #expect(nested - child == child - host)
    }

    @Test("tmux action hover does not change reserved row width")
    func tmuxActionHoverKeepsStableRowWidth() {
        let idle = WorkspaceTmuxSessionActionPresentation(
            hasTmuxSession: true,
            isRowHovered: false,
            isActionHovered: false
        )
        let hovered = WorkspaceTmuxSessionActionPresentation(
            hasTmuxSession: true,
            isRowHovered: true,
            isActionHovered: false
        )

        #expect(!idle.isVisible)
        #expect(hovered.isVisible)
        #expect(idle.reservedWidth == hovered.reservedWidth)
        #expect(idle.reservedWidth > 0)
        #expect(hovered.hitTargetWidth >= 28)
    }

    @Test("worktree removal is subtle without shrinking its hit target")
    func worktreeRemovalHoverKeepsStableHitTarget() {
        let idle = WorkspaceWorktreeRemovalActionPresentation(
            isRemovable: true,
            isRowHovered: false,
            isActionHovered: false
        )
        let hovered = WorkspaceWorktreeRemovalActionPresentation(
            isRemovable: true,
            isRowHovered: true,
            isActionHovered: false
        )
        let primary = WorkspaceWorktreeRemovalActionPresentation(
            isRemovable: false,
            isRowHovered: true,
            isActionHovered: true
        )

        #expect(!idle.isVisible)
        #expect(hovered.isVisible)
        #expect(idle.reservedWidth == hovered.reservedWidth)
        #expect(hovered.hitTargetWidth >= 28)
        #expect(!primary.isVisible)
        #expect(primary.reservedWidth == 0)
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
        #expect(sections.allSatisfy { $0.isEmpty })
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

    @Test("a worktree keeps its standalone kill action when its session is live")
    func resolvesKillableWorktreeSession() {
        let hostID = UUID()
        var worktree = WorktreeSummary.fixture(hostID: hostID)
        worktree.tmuxSessionName = "kwt-ghosthub-topic"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(
                    id: hostID,
                    tmuxSessions: [
                        TmuxSessionSummary(
                            name: "kwt-ghosthub-topic",
                            managed: true,
                            windows: [],
                            serverPID: "4242",
                            sessionID: "$3",
                            createdAt: "1785190000"
                        ),
                    ]
                ),
            ],
            worktrees: [worktree]
        )

        #expect(
            WorkspaceSidebarModel.killableTmuxSession(
                for: worktree,
                in: snapshot
            ) == WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "kwt-ghosthub-topic",
                worktreeID: worktree.id,
                worktreePath: worktree.path
            )
        )
    }

    @Test("kill eligibility requires discovery or an active attachment")
    func runningSessionEvidence() {
        let hostID = UUID()
        let snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(
                id: hostID,
                tmuxSessions: [
                    TmuxSessionSummary(
                        name: "training",
                        managed: false,
                        windows: [],
                        serverPID: "4242",
                        sessionID: "$3",
                        createdAt: "1785190000"
                    ),
                    TmuxSessionSummary(
                        name: "optimistic",
                        managed: false,
                        windows: []
                    ),
                    TmuxSessionSummary(
                        name: "malformed",
                        managed: false,
                        windows: [],
                        serverPID: "not-a-pid",
                        sessionID: "$4",
                        createdAt: "1785190001"
                    ),
                ]
            ),
        ])
        let discovered = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "training"
        )
        let protected = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "pr-519",
            socketName: "kwt-pr-0123456789abcdef"
        )
        let optimistic = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "optimistic"
        )
        let malformed = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "malformed"
        )

        #expect(WorkspaceSidebarModel.canRequestKill(
            discovered,
            in: snapshot
        ))
        #expect(!WorkspaceSidebarModel.canRequestKill(
            optimistic,
            in: snapshot
        ))
        #expect(!WorkspaceSidebarModel.canRequestKill(
            malformed,
            in: snapshot
        ))
        #expect(!WorkspaceSidebarModel.canRequestKill(
            protected,
            in: snapshot,
            activeSelection: protected
        ))
        #expect(WorkspaceSidebarModel.canRequestKill(
            protected,
            in: snapshot,
            activeSelection: protected,
            activeSelectionIsConnected: true
        ))
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

    @Test("hidden patterns remove only standalone tmux session rows")
    func hiddenPatternsRemoveStandaloneSessions() {
        let hostID = UUID()
        let projectID = UUID()
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "forge-project",
            path: "/code/forge-project",
            branch: "main"
        )
        worktree.tmuxSessionName = "forge-worktree"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(
                    id: hostID,
                    tmuxSessions: [
                        TmuxSessionSummary(
                            name: "forge-2ce60210419f1730",
                            managed: false,
                            windows: []
                        ),
                        TmuxSessionSummary(
                            name: "forge-worktree",
                            managed: false,
                            windows: []
                        ),
                        TmuxSessionSummary(
                            name: "homelab",
                            managed: false,
                            windows: []
                        ),
                    ]
                ),
            ],
            projects: [
                .fixture(
                    id: projectID,
                    hostID: hostID,
                    name: "forge-project",
                    rootPath: "/code/forge-project"
                ),
            ],
            worktrees: [worktree]
        )

        let sections = WorkspaceSidebarModel.sections(
            in: snapshot,
            tmuxSessionVisibility: TmuxSessionVisibility(
                hiddenPatterns: ["forge-*"]
            )
        )

        #expect(sections[0].tmuxSessionRows.map(\.title) == ["homelab"])
        #expect(sections[0].projects[0].worktrees.map(\.id) == [worktree.id])
    }

    @Test("protected workspace names never hide default-server sessions")
    func keepsDefaultServerSessionSharingProtectedName() {
        let hostID = UUID()
        let projectID = UUID()
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "pr-32",
            path: "/code/docbank-pr-32",
            branch: "contributor/pr-32"
        )
        worktree.tmuxSessionName = "kwt-docbank-pr-32"
        worktree.tmuxSocketName = "kwt-pr-0123456789abcdef"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(
                    id: hostID,
                    tmuxSessions: [
                        TmuxSessionSummary(
                            name: "kwt-docbank-pr-32",
                            managed: false,
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

        #expect(
            sections[0].tmuxSessionRows.map(\.title) == ["kwt-docbank-pr-32"]
        )
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
