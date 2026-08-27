import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

struct WorkspaceSidebarModelTests {
    @MainActor
    @Test("section cache refreshes only when its inputs change")
    func sectionCacheInvalidation() {
        let hostID = UUID()
        let cache = WorkspaceSidebarSectionCache()
        var snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(
                id: hostID,
                tmuxSessions: [
                    .init(name: "first", managed: false, windows: []),
                ]
            ),
        ])

        let first = cache.sections(in: snapshot, snapshotRevision: 0)
        let repeated = cache.sections(in: snapshot, snapshotRevision: 0)
        #expect(first == repeated)

        snapshot.hosts[0].tmuxSessions.append(
            .init(name: "second", managed: false, windows: [])
        )
        let refreshed = cache.sections(in: snapshot, snapshotRevision: 1)
        #expect(refreshed[0].tmuxSessionRows.map(\.title)
            == ["first", "second"])
    }

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

    @Test("removed inventory identities are pruned from persisted order")
    func prunesRemovedInventoryIdentities() {
        var order = WorkspaceSidebarOrder(
            rawValue: "present\nremoved\nhidden"
        )

        let didPrune = order.prune(keeping: ["present", "hidden"])
        #expect(didPrune)
        #expect(order.rawValue == "present\nhidden")
        let didPruneAgain = order.prune(keeping: ["present", "hidden"])
        #expect(!didPruneAgain)
    }

    @Test("staggered inventory results cannot trigger order pruning")
    func incompleteInventoryDoesNotPrune() {
        #expect(!WorkspaceSidebarPruningPolicy.shouldPrune(
            refreshComplete: false,
            inventoryWarning: nil,
            inventoryWarningsByHost: [:]
        ))
        #expect(WorkspaceSidebarPruningPolicy.shouldPrune(
            refreshComplete: true,
            inventoryWarning: nil,
            inventoryWarningsByHost: [:]
        ))
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

    @Test("Herdr sessions use an independent row model and ordering")
    func herdrSessionRowsAndOrdering() {
        let hostID = UUID()
        let herdrSessions = [
            HerdrSessionSummary(name: "alpha", isDefault: false, state: .running),
            HerdrSessionSummary(name: "beta", isDefault: true, state: .running),
            HerdrSessionSummary(name: "gamma", isDefault: false, state: .stopped),
        ]
        let host = HostSummary.fixture(
            id: hostID,
            tmuxSessions: [
                TmuxSessionSummary(
                    name: "tmux-kept",
                    managed: false,
                    windows: []
                ),
            ],
            herdrSessions: herdrSessions.reversed()
        )
        let ids = herdrSessions.map {
            WorkspaceSidebarModel.herdrSessionOrderID(
                hostID: hostID,
                name: $0.name
            )
        }
        var order = WorkspaceSidebarOrder()
        let didMove = order.move(ids[0], to: ids[2], within: ids)
        #expect(didMove)

        let section = WorkspaceSidebarModel.sections(
            in: WorkspaceSnapshot(
                hosts: [host],
                projects: [
                    .fixture(hostID: hostID, name: "ghosthub"),
                ],
                worktrees: []
            ),
            herdrSessionOrderRawValue: order.rawValue
        )[0]

        #expect(section.tmuxSessionRows.map(\.title) == ["tmux-kept"])
        #expect(section.herdrSessionRows.map(\.title)
            == ["beta", "gamma", "alpha"])
        #expect(section.herdrSessionRows.map(\.subtitle)
            == ["Herdr session", "Stopped", "Herdr session"])
        #expect(section.herdrSessionRows[0].target == .herdrSession(
            hostID: hostID,
            name: "beta"
        ))
        #expect(section.herdrSessionRows[0].icon == .herdrSession)
        #expect(section.herdrSessionRows[0].subtitle == "Herdr session")
        #expect(section.herdrSessionRows[0].indentLevel == 0)
        #expect(section.visibleGroups == [
            .tmuxSessions, .herdrSessions, .projects,
        ])
    }

    @Test("section emptiness includes Herdr inventory")
    func herdrAffectsSectionEmptiness() {
        let empty = WorkspaceSidebarModel.sections(
            in: .fixture(hosts: [.fixture()])
        )[0]
        let herdr = WorkspaceSidebarModel.sections(
            in: .fixture(hosts: [
                .fixture(herdrSessions: [
                    HerdrSessionSummary(name: "api", isDefault: true, state: .running),
                ]),
            ])
        )[0]

        #expect(empty.herdrSessionRows.isEmpty)
        #expect(empty.isEmpty)
        #expect(!herdr.isEmpty)
    }

    @Test("Zellij sessions have an independent group and ordering")
    func zellijSessionRowsAndOrdering() {
        let hostID = UUID()
        let sessions = ["alpha", "beta", "gamma"]
        let host = HostSummary.fixture(
            id: hostID,
            zellijSessions: sessions.reversed().map(
                ZellijSessionSummary.init(name:)
            ),
            zellijAvailable: true
        )
        let ids = sessions.map {
            WorkspaceSidebarModel.zellijSessionOrderID(
                hostID: hostID,
                name: $0
            )
        }
        var order = WorkspaceSidebarOrder()
        let didMove = order.move(ids[0], to: ids[2], within: ids)
        #expect(didMove)

        let section = WorkspaceSidebarModel.sections(
            in: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            zellijSessionOrderRawValue: order.rawValue
        )[0]

        #expect(section.zellijSessionRows.map(\.title)
            == ["beta", "gamma", "alpha"])
        #expect(section.zellijSessionRows[0].target == .zellijSession(
            hostID: hostID,
            name: "beta"
        ))
        #expect(section.zellijSessionRows[0].icon == .zellijSession)
        #expect(section.zellijSessionRows[0].subtitle == "Zellij session")
        #expect(section.visibleGroups == [.zellijSessions])
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

    @Test("session actions appear on hover or selection without shifting rows")
    func sessionActionsStayDiscoverableAndStable() {
        let idle = WorkspaceSessionActionPresentation(
            hasActions: true,
            isRowHovered: false,
            isActionHovered: false,
            isSelected: false
        )
        let selected = WorkspaceSessionActionPresentation(
            hasActions: true,
            isRowHovered: false,
            isActionHovered: false,
            isSelected: true
        )
        let hovered = WorkspaceSessionActionPresentation(
            hasActions: true,
            isRowHovered: true,
            isActionHovered: false,
            isSelected: false
        )
        let unavailable = WorkspaceSessionActionPresentation(
            hasActions: false,
            isRowHovered: true,
            isActionHovered: true,
            isSelected: true
        )

        #expect(!idle.isVisible)
        #expect(selected.isVisible)
        #expect(hovered.isVisible)
        #expect(!unavailable.isVisible)
        #expect(idle.reservedWidth == selected.reservedWidth)
        #expect(selected.hitTargetWidth >= 28)
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

    @Test("project removal appears on hover or keyboard focus")
    func projectRemovalHoverAndFocusKeepStableHitTarget() {
        let idle = WorkspaceProjectRemovalActionPresentation(
            isRemovable: true,
            isRowHovered: false,
            isActionHovered: false,
            isFocused: false
        )
        let hovered = WorkspaceProjectRemovalActionPresentation(
            isRemovable: true,
            isRowHovered: true,
            isActionHovered: false,
            isFocused: false
        )
        let focused = WorkspaceProjectRemovalActionPresentation(
            isRemovable: true,
            isRowHovered: false,
            isActionHovered: false,
            isFocused: true
        )
        let unavailable = WorkspaceProjectRemovalActionPresentation(
            isRemovable: false,
            isRowHovered: true,
            isActionHovered: true,
            isFocused: true
        )

        #expect(!idle.isVisible)
        #expect(hovered.isVisible)
        #expect(focused.isVisible)
        #expect(!unavailable.isVisible)
        #expect(idle.reservedWidth == hovered.reservedWidth)
        #expect(focused.hitTargetWidth >= 28)
        #expect(unavailable.reservedWidth == 0)
    }

    @Test("hosts remain visible before they have projects or tmux sessions")
    func exposesEmptyHosts() {
        let local = HostSummary.fixture(name: "This Mac")
        let remote = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            sshDestination: "user-a@build-box"
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
        let herdrSessionsKey = WorkspaceSidebarDisclosureState
            .herdrSessions(hostID)
        let projectsKey = WorkspaceSidebarDisclosureState.projects(hostID)
        let projectKey = WorkspaceSidebarDisclosureState.project(projectID)
        var state = WorkspaceSidebarDisclosureState()

        #expect(state.isExpanded(hostKey))
        #expect(state.isExpanded(sessionsKey))
        #expect(state.isExpanded(herdrSessionsKey))
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

    @Test("Herdr ordering has its own persisted storage key")
    func herdrOrderStorageKey() {
        #expect(
            WorkspaceSidebarOrderStorage.herdrSessionKey
                == "workspaceSidebarHerdrSessionOrderV1"
        )
        #expect(
            WorkspaceSidebarOrderStorage.herdrSessionKey
                != WorkspaceSidebarOrderStorage.tmuxSessionKey
        )
    }

    @Test("Herdr rows preserve running and stopped state")
    func herdrRowState() {
        let hostID = UUID()
        let snapshot = WorkspaceSnapshot.fixture(hosts: [
            .fixture(
                id: hostID,
                herdrSessions: [
                    .init(name: "running", isDefault: true, state: .running),
                    .init(name: "stopped", isDefault: false, state: .stopped),
                ]
            ),
        ])

        let rows = WorkspaceSidebarModel.sections(in: snapshot)[0]
            .herdrSessionRows
        let running = rows.first { $0.title == "running" }
        let stopped = rows.first { $0.title == "stopped" }
        #expect(running?.herdrSessionState == .running)
        #expect(running?.herdrSessionIsDefault == true)
        #expect(stopped?.herdrSessionState == .stopped)
        #expect(stopped?.herdrSessionIsDefault == false)
        #expect(stopped?.subtitle == "Stopped")
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
                worktreePath: worktree.path,
                tmuxAttachMode: .direct
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
                worktreePath: worktree.path,
                tmuxAttachMode: .direct
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
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected
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
                    sshDestination: "user-a@build-box",
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
        #expect(
            sections[0].projects[0].worktreeRows[0]
                .worktreeStatus?.isRunning == true
        )

        let showingKwtSessions = WorkspaceSidebarModel.sections(
            in: snapshot,
            tmuxSessionVisibility: TmuxSessionVisibility(
                hideKwtManagedSessions: false
            )
        )

        #expect(showingKwtSessions[0].tmuxSessionRows.map(\.title) == [
            "external-agent", "kwt-docbank-main",
        ])

        var unreachableSnapshot = snapshot
        unreachableSnapshot.hosts[0].lastKnownReachable = false
        let unreachableSections = WorkspaceSidebarModel.sections(
            in: unreachableSnapshot
        )
        #expect(
            unreachableSections[0].projects[0].worktreeRows[0]
                .worktreeStatus?.isRunning == false
        )
    }

    @Test("directory workspaces are flat project-level rows after repositories")
    func exposesDirectoryWorkspacesAfterProjects() {
        let hostID = UUID()
        let projectID = UUID()
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: hostID,
            name: "jibot",
            path: "/workspaces/jibot",
            tmuxSessionName: "kwt-workspace-dir-jibot-abc",
            sessionLive: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(
                id: hostID,
                tmuxSessions: [.init(
                    name: directory.tmuxSessionName,
                    managed: true,
                    windows: [],
                    serverPID: "4242",
                    sessionID: "$3",
                    createdAt: "1785190000"
                )]
            )],
            projects: [.fixture(
                id: projectID,
                hostID: hostID,
                name: "ghosthub"
            )],
            worktrees: [],
            directoryWorkspaces: [directory]
        )

        let section = WorkspaceSidebarModel.sections(in: snapshot)[0]

        #expect(section.projects.map(\.project.id) == [projectID])
        #expect(section.directoryWorkspaceRows == [
            WorkspaceSidebarRow(
                target: .directoryWorkspace(directory.id),
                icon: .directoryWorkspace,
                title: "jibot",
                subtitle: "/workspaces/jibot",
                sessionIsRunning: true
            ),
        ])
        #expect(section.tmuxSessionRows.isEmpty)
        #expect(
            WorkspaceSidebarModel.tmuxSessionSelection(
                for: directory
            ) == WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: directory.tmuxSessionName,
                directoryWorkspaceID: directory.id,
                workspacePath: directory.path,
                tmuxAttachMode: .direct
            )
        )
        let selection = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )
        #expect(WorkspaceSidebarModel.canRequestKill(
            selection,
            in: snapshot
        ))

        var unregistered = snapshot
        unregistered.directoryWorkspaces = []
        #expect(
            WorkspaceSidebarModel.sections(in: unregistered)[0]
                .tmuxSessionRows.map(\.title) == [directory.tmuxSessionName]
        )
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
        #expect(
            sections[0].projects[0].worktreeRows[0]
                .worktreeStatus?.isRunning == false
        )
    }

    @Test("worktree rows expose only trusted positive tmux window counts")
    func worktreeWindowCounts() throws {
        let hostID = UUID()
        let projectID = UUID()
        var counted = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "counted"
        )
        counted.tmuxSessionName = "kwt-wt-ghosthub-counted-12345678"
        var protected = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "protected"
        )
        protected.tmuxSessionName = "kwt-wt-ghosthub-protected-12345678"
        protected.tmuxSocketName = "kwt-pr-0123456789abcdef"
        var empty = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "empty"
        )
        empty.tmuxSessionName = "kwt-wt-ghosthub-empty-12345678"
        var absent = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "absent"
        )
        absent.tmuxSessionName = "kwt-wt-ghosthub-absent-12345678"
        let sessions = [
            TmuxSessionSummary(
                name: "kwt-wt-ghosthub-counted-12345678",
                managed: true,
                windows: [
                    .init(id: "@1", index: 0, name: "editor"),
                    .init(id: "@2", index: 1, name: "tests"),
                    .init(id: "@3", index: 2, name: "review"),
                ]
            ),
            TmuxSessionSummary(
                name: "kwt-wt-ghosthub-protected-12345678",
                managed: false,
                windows: [
                    .init(id: "@4", index: 0, name: "unrelated"),
                ]
            ),
            TmuxSessionSummary(
                name: "kwt-wt-ghosthub-empty-12345678",
                managed: true,
                windows: []
            ),
        ]
        let project = ProjectSummary.fixture(id: projectID, hostID: hostID)
        let worktrees = [counted, protected, empty, absent]
        let reachable = WorkspaceSidebarModel.sections(
            in: WorkspaceSnapshot.fixture(
                hosts: [.fixture(id: hostID, tmuxSessions: sessions)],
                projects: [project],
                worktrees: worktrees
            )
        )[0]
        let reachableRows = Dictionary(uniqueKeysWithValues:
            reachable.projects[0].worktreeRows.map { ($0.title, $0) })

        #expect(try #require(reachableRows["counted"])
            .worktreeStatus?.tmuxWindowCount == 3)
        #expect(try #require(reachableRows["protected"])
            .worktreeStatus?.tmuxWindowCount == nil)
        #expect(try #require(reachableRows["empty"])
            .worktreeStatus?.tmuxWindowCount == nil)
        #expect(try #require(reachableRows["absent"])
            .worktreeStatus?.tmuxWindowCount == nil)

        let connectedSessionIDs = Set([
            try #require(
                WorkspaceSidebarModel.tmuxSessionSelection(for: counted)
            ).id,
            try #require(
                WorkspaceSidebarModel.tmuxSessionSelection(for: protected)
            ).id,
        ])
        let liveWindowCounts = Dictionary(uniqueKeysWithValues: [
            (
                try #require(
                    WorkspaceSidebarModel.tmuxSessionSelection(for: counted)
                ).id,
                4
            ),
            (
                try #require(
                    WorkspaceSidebarModel.tmuxSessionSelection(for: protected)
                ).id,
                2
            ),
        ])
        let untrusted = WorkspaceSidebarModel.sections(
            in: WorkspaceSnapshot.fixture(
                hosts: [
                    .fixture(
                        id: hostID,
                        tmuxSessions: sessions,
                        tmuxInventoryIsAuthoritative: false
                    ),
                ],
                projects: [project],
                worktrees: [counted, protected]
            ),
            connectedTmuxSessionIDs: connectedSessionIDs,
            liveTmuxWindowCounts: liveWindowCounts
        )[0]
        let untrustedRows = Dictionary(uniqueKeysWithValues:
            untrusted.projects[0].worktreeRows.map { ($0.title, $0) })

        #expect(try #require(untrustedRows["counted"])
            .worktreeStatus?.tmuxWindowCount == 4)
        #expect(try #require(untrustedRows["protected"])
            .worktreeStatus?.tmuxWindowCount == 2)

        let unreachable = WorkspaceSidebarModel.sections(
            in: WorkspaceSnapshot.fixture(
                hosts: [
                    .fixture(
                        id: hostID,
                        lastKnownReachable: false,
                        tmuxSessions: sessions
                    ),
                ],
                projects: [project],
                worktrees: [counted]
            )
        )[0]
        #expect(unreachable.projects[0].worktreeRows[0]
            .worktreeStatus?.tmuxWindowCount == nil)
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
