import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

struct WorkspaceSidebarModelTests {
    @Test("every backend shares one session list, by backend then name by default")
    func mergedSessionListDefaultsToBackendOrder() {
        let hostID = UUID()
        let host = HostSummary.fixture(
            id: hostID,
            tmuxSessions: [
                .init(name: "zeta", managed: false, windows: []),
                .init(name: "alpha", managed: false, windows: []),
            ],
            herdrSessions: [
                .init(name: "t1", isDefault: false, state: .running),
                .init(
                    name: "t9",
                    isDefault: false,
                    state: .running,
                    backend: .core,
                    title: "review"
                ),
            ],
            herdrAvailable: true,
            zellijSessions: [.init(name: "docs")],
            zellijAvailable: true
        )
        let section = WorkspaceSidebarModel.sections(in: .fixture(hosts: [host]))[0]

        #expect(section.sessionRows.map(\.title) == [
            "alpha", "zeta", "docs", "review", "t1",
        ])
        #expect(section.sessionRows.map(\.sessionBackend) == [
            .tmux, .tmux, .zellij, .herdrTerminal, .herdrTUI,
        ])
        #expect(section.sessionRows(for: .herdrTerminal).map(\.target) == [
            .herdrSession(hostID: hostID, name: "t9", backend: .core),
        ])
        // Only desktop terminals show their address after the name.
        #expect(section.sessionRows.map(\.sessionDetail) == [
            nil, nil, nil, "t9", nil,
        ])
    }

    @Test("a manual drag moves a session across backends")
    func manualOrderCrossesBackends() {
        let hostID = UUID()
        let host = HostSummary.fixture(
            id: hostID,
            tmuxSessions: [.init(name: "build", managed: false, windows: [])],
            herdrSessions: [.init(name: "agent", isDefault: false, state: .running)],
            zellijSessions: [.init(name: "docs")]
        )
        let rows = WorkspaceSidebarModel.sections(in: .fixture(hosts: [host]))[0]
            .sessionRows
        let ids = rows.compactMap(\.sessionOrderID)
        var order = WorkspaceSidebarOrder()
        // Drop the Herdr session onto the tmux session.
        let moved = order.move(ids[2], to: ids[0], within: ids)
        #expect(moved)

        let reordered = WorkspaceSidebarModel.sections(
            in: .fixture(hosts: [host]),
            sessionOrderRawValue: order.rawValue
        )[0].sessionRows
        #expect(reordered.map(\.title) == ["agent", "build", "docs"])
    }

    @Test(
        "each sort mode orders sessions and stopped Herdr sessions sink",
        arguments: [
            (SidebarSessionSort.manual, ["zed", "beta", "docs", "alpha", "parked"]),
            (.name, ["alpha", "beta", "docs", "zed", "parked"]),
            (.backend, ["alpha", "beta", "zed", "docs", "parked"]),
            (.attention, ["beta", "alpha", "zed", "docs", "parked"]),
        ]
    )
    func sortModes(sort: SidebarSessionSort, expected: [String]) {
        let hostID = UUID()
        let host = HostSummary.fixture(
            id: hostID,
            tmuxSessions: ["alpha", "beta", "zed"].map {
                .init(name: $0, managed: false, windows: [])
            },
            herdrSessions: [
                .init(name: "parked", isDefault: false, state: .stopped),
            ],
            zellijSessions: [.init(name: "docs")]
        )
        let manual = [
            WorkspaceSidebarModel.herdrSessionOrderID(hostID: hostID, name: "parked"),
            WorkspaceSidebarModel.tmuxSessionOrderID(hostID: hostID, name: "zed"),
            WorkspaceSidebarModel.tmuxSessionOrderID(hostID: hostID, name: "beta"),
            WorkspaceSidebarModel.zellijSessionOrderID(hostID: hostID, name: "docs"),
            WorkspaceSidebarModel.tmuxSessionOrderID(hostID: hostID, name: "alpha"),
        ].joined(separator: "\n")
        let attention: [String: AgentAttention] = [
            AgentAttentionStore.endpointKey(hostID: hostID, name: "alpha", socketName: nil):
                .working(agent: "Claude"),
            AgentAttentionStore.endpointKey(hostID: hostID, name: "beta", socketName: nil):
                .approval(agent: "Codex"),
        ]

        let rows = WorkspaceSidebarModel.sections(
            in: .fixture(hosts: [host]),
            sessionOrderRawValue: manual,
            sessionSort: sort,
            agentAttentionByEndpoint: attention
        )[0].sessionRows

        #expect(rows.map(\.title) == expected)
    }

    @Test("the host menu lists every backend and disables unavailable ones")
    func hostMenuEntries() {
        let bare = HostSummary.fixture(platform: .windows)
        let entries = WorkspaceSidebarHostMenuModel.entries(for: bare)
        #expect(entries.count == 1)
        #expect(entries[0].map(\.item) == [
            .newTmuxSession, .newZellijSession, .newHerdrSession,
        ])
        #expect(entries[0].map(\.isEnabled) == [true, false, false])
        #expect(entries[0][1].help?.contains("Zellij") == true)

        let full = HostSummary.fixture(
            platform: .macOS,
            herdrAvailable: true,
            zellijAvailable: true
        )
        let fullEntries = WorkspaceSidebarHostMenuModel.entries(for: full)
        #expect(fullEntries.flatMap { $0 }.allSatisfy { $0.isEnabled })
        #expect(fullEntries.last?.map(\.item) == [.addProject])
    }

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
        #expect(refreshed[0].sessionRows(for: .tmux).map(\.title)
            == ["first", "second"])
    }

    @MainActor
    @Test("agent attention rebuilds the cached sidebar only in the attention sort")
    func sectionCacheAttentionInput() {
        let hostID = UUID()
        let cache = WorkspaceSidebarSectionCache()
        let snapshot = WorkspaceSnapshot.fixture(hosts: [.fixture(
            id: hostID,
            tmuxSessions: ["first", "second"].map {
                .init(name: $0, managed: false, windows: [])
            }
        )])
        let secondNeedsApproval: [String: AgentAttention] = [
            AgentAttentionStore.endpointKey(
                hostID: hostID, name: "second", socketName: nil
            ): .approval(agent: "Codex"),
        ]
        func titles(
            _ sort: SidebarSessionSort,
            _ attention: [String: AgentAttention],
            in snapshot: WorkspaceSnapshot
        ) -> [String] {
            cache.sections(
                in: snapshot,
                snapshotRevision: 0,
                sessionSort: sort,
                agentAttentionByEndpoint: attention
            )[0].sessionRows.map(\.title)
        }

        #expect(titles(.attention, [:], in: snapshot) == ["first", "second"])
        #expect(titles(.attention, secondNeedsApproval, in: snapshot)
            == ["second", "first"])

        // Outside the attention sort, an attention change is a cache hit: the
        // sections come back unchanged even from a mutated snapshot that
        // kept its revision.
        #expect(titles(.manual, [:], in: snapshot) == ["first", "second"])
        var mutated = snapshot
        mutated.hosts[0].tmuxSessions.removeAll()
        #expect(titles(.manual, secondNeedsApproval, in: mutated)
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
            sessionOrderRawValue: order.rawValue
        )

        #expect(sections[0].sessionRows(for: .tmux).map(\.title)
            == ["beta", "gamma", "alpha"])
        #expect(sections[1].sessionRows(for: .tmux).map(\.title)
            == ["alpha", "beta", "gamma"])
    }

    @Test("Herdr rows report state and stopped sessions sink below running ones")
    func herdrSessionRowsAndOrdering() {
        let hostID = UUID()
        let host = HostSummary.fixture(
            id: hostID,
            tmuxSessions: [
                TmuxSessionSummary(name: "tmux-kept", managed: false, windows: []),
            ],
            herdrSessions: [
                HerdrSessionSummary(name: "gamma", isDefault: false, state: .stopped),
                HerdrSessionSummary(name: "beta", isDefault: true, state: .running),
                HerdrSessionSummary(name: "alpha", isDefault: false, state: .running),
            ]
        )

        let section = WorkspaceSidebarModel.sections(
            in: WorkspaceSnapshot(hosts: [host], projects: [], worktrees: [])
        )[0]

        #expect(section.sessionRows.map(\.title)
            == ["tmux-kept", "alpha", "beta", "gamma"])
        let herdr = section.sessionRows(for: .herdrTUI)
        #expect(herdr.map(\.subtitle) == ["Running", "Running", "Stopped"])
        #expect(herdr[1].target == .herdrSession(hostID: hostID, name: "beta"))
        #expect(herdr[1].icon == .herdrSession)
        #expect(herdr[1].indentLevel == 0)
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

        #expect(empty.sessionRows(for: .herdrTUI).isEmpty)
        #expect(empty.isEmpty)
        #expect(!herdr.isEmpty)
    }

    @Test("Zellij rows carry no subtitle beyond their backend label")
    func zellijSessionRows() {
        let hostID = UUID()
        let host = HostSummary.fixture(
            id: hostID,
            zellijSessions: [ZellijSessionSummary(name: "beta")],
            zellijAvailable: true
        )

        let row = WorkspaceSidebarModel.sections(
            in: WorkspaceSnapshot(hosts: [host], projects: [], worktrees: [])
        )[0].sessionRows[0]

        #expect(row.target == .zellijSession(hostID: hostID, name: "beta"))
        #expect(row.sessionBackend == .zellij)
        #expect(row.subtitle == nil)
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

    @Test("worktree disclosure occupies its hierarchy indent")
    func worktreeDisclosureUsesChildIndent() {
        let rowLevel = 1
        let presentation = WorkspaceWorktreeDisclosurePresentation(
            rowIndentLevel: rowLevel
        )

        #expect(
            presentation.leadingIndent
                == WorkspaceSidebarHierarchy.indent(level: rowLevel)
        )
        #expect(presentation.contentIndentLevel == 0)
        #expect(
            presentation.leadingIndent
                + WorkspaceSidebarHierarchy.indent(
                    level: presentation.contentIndentLevel
                )
                == WorkspaceSidebarHierarchy.indent(level: rowLevel)
        )
    }

    @Test("session actions appear on hover or selection beside, not over, the label")
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
        // Rows with and without actions keep their labels in one column.
        #expect(idle.reservedWidth == selected.reservedWidth)
        #expect(unavailable.reservedWidth == selected.reservedWidth)
        // The control fits the space after the label, so it never covers it.
        #expect(
            WorkspaceSessionActionPresentation.trailingInset
                + selected.hitTargetWidth
                <= WorkspaceSessionActionPresentation.rowTrailingPadding
                + selected.reservedWidth
        )
        #expect(unavailable.hitTargetWidth == 0)
    }

    @Test("worktree actions reserve one stable slot with or without a session")
    func worktreeActionsKeepStableHitTarget() {
        let idle = WorkspaceWorktreeActionPresentation(
            isRowHovered: false,
            isActionHovered: false,
            isSelected: false,
            isFocused: false
        )
        let hovered = WorkspaceWorktreeActionPresentation(
            isRowHovered: true,
            isActionHovered: false,
            isSelected: false,
            isFocused: false
        )
        let focused = WorkspaceWorktreeActionPresentation(
            isRowHovered: false,
            isActionHovered: false,
            isSelected: false,
            isFocused: true
        )
        let selected = WorkspaceWorktreeActionPresentation(
            isRowHovered: false,
            isActionHovered: false,
            isSelected: true,
            isFocused: false
        )

        #expect(!idle.isVisible)
        #expect(hovered.isVisible)
        #expect(focused.isVisible)
        #expect(idle.reservedWidth == hovered.reservedWidth)
        #expect(hovered.hitTargetWidth >= 28)
        #expect(selected.isVisible)
        #expect(idle.reservedWidth == 30)
        #expect(selected.reservedWidth == 30)
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
        #expect(sections.allSatisfy { $0.sessionRows(for: .tmux).isEmpty })
        #expect(sections.allSatisfy { $0.isEmpty })
    }

    @Test("sidebar disclosure defaults expose fleet before project contents")
    func sidebarDisclosureDefaultsAndToggles() {
        let hostID = UUID()
        let projectID = UUID()
        let hostKey = WorkspaceSidebarDisclosureState.host(hostID)
        let projectsKey = WorkspaceSidebarDisclosureState.projects(hostID)
        let projectKey = WorkspaceSidebarDisclosureState.project(projectID)
        var state = WorkspaceSidebarDisclosureState()

        #expect(state.isExpanded(hostKey))
        #expect(!state.isExpanded(projectsKey))
        #expect(!state.isExpanded(projectKey))

        state.toggle(hostKey)
        #expect(!state.isExpanded(hostKey))
        state.toggle(hostKey)
        state.toggle(projectsKey)
        state.toggle(projectKey)
        #expect(state.isExpanded(hostKey))
        #expect(state.isExpanded(projectsKey))
        #expect(state.isExpanded(projectKey))

        state.toggle(projectKey)
        #expect(!state.isExpanded(projectKey))
        state.toggle(projectsKey)
        #expect(!state.isExpanded(projectsKey))
        #expect(state == WorkspaceSidebarDisclosureState())
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
            .sessionRows(for: .herdrTUI)
        let running = rows.first { $0.title == "running" }
        let stopped = rows.first { $0.title == "stopped" }
        #expect(running?.herdrSessionState == .running)
        #expect(running?.herdrSessionIsDefault == true)
        #expect(stopped?.herdrSessionState == .stopped)
        #expect(stopped?.herdrSessionIsDefault == false)
        #expect(stopped?.subtitle == "Stopped")
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

    @Test("rename is refused for sessions kwt owns, even as plain rows")
    func renameEligibilityExcludesKwtSessions() {
        let hostID = UUID()
        var worktree = WorktreeSummary.fixture(hostID: hostID)
        worktree.tmuxSessionName = "desk"
        worktree.tmuxSocketName = nil
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: hostID,
            name: "notes",
            path: "/workspaces/notes",
            tmuxSessionName: "notes",
            sessionLive: true
        )
        let names = ["desk", "notes", "kwt-wt-ghosthub-main-abc", "scratch"]
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(
                id: hostID,
                tmuxSessions: names.enumerated().map { index, name in
                    TmuxSessionSummary(
                        name: name,
                        managed: false,
                        windows: [],
                        serverPID: "4242",
                        sessionID: "$\(index)",
                        createdAt: "1785190000"
                    )
                }
            )],
            projects: [],
            worktrees: [worktree],
            directoryWorkspaces: [directory]
        )

        let renamable = names.filter {
            WorkspaceSidebarModel.canRequestRename(
                WorkspaceTmuxSessionSelection(hostID: hostID, name: $0),
                in: snapshot
            )
        }
        #expect(renamable == ["scratch"])
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
        #expect(sections[0].sessionRows(for: .tmux).map(\.title) == [
            "docbank", "kwt-workspace-core",
        ])
        #expect(sections[0].sessionRows(for: .tmux)[0].target == .tmuxSession(
            hostID: hostID,
            name: "docbank"
        ))
        #expect(sections[0].sessionRows(for: .tmux)[0].subtitle == "1 window")
        #expect(sections[0].sessionRows(for: .tmux)[0].icon == .tmuxSession)
        #expect(sections[0].sessionRows(for: .tmux)[0].indentLevel == 0)
        #expect(sections[0].sessionRows(for: .tmux)[1].subtitle == "Workspace session")
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

        #expect(sections[0].sessionRows(for: .tmux).map(\.title) == ["external-agent"])
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

        #expect(showingKwtSessions[0].sessionRows(for: .tmux).map(\.title) == [
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
        #expect(section.sessionRows(for: .tmux).isEmpty)
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
                .sessionRows(for: .tmux).map(\.title) == [directory.tmuxSessionName]
        )
    }

    @Test("same-name tmux sessions keep socket-specific rows, counts, and ownership")
    func tmuxRowsKeepSocketIdentity() {
        let hostID = UUID()
        let projectID = UUID()
        let defaultSelection = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let kwtSelection = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "desk",
            socketName: "kwt"
        )
        let sessions = [nil, "kwt"].map { socket in
            TmuxSessionSummary(
                name: "desk",
                socketName: socket,
                managed: false,
                windows: [],
                serverPID: socket == nil ? "101" : "202",
                sessionID: "$1",
                createdAt: "1000"
            )
        }
        var worktree = WorktreeSummary.fixture(hostID: hostID, projectID: projectID)
        worktree.tmuxSessionName = "desk"
        worktree.tmuxSocketName = "kwt"
        worktree.tmuxAttachMode = .direct
        var snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID, tmuxSessions: sessions)],
            projects: [.fixture(id: projectID, hostID: hostID)],
            worktrees: [worktree]
        )
        let visible = WorkspaceSidebarModel.sections(in: snapshot)[0]
        #expect(visible.sessionRows(for: .tmux).map(\.target) == [.tmuxSession(
            hostID: hostID,
            name: "desk"
        )])

        let all = WorkspaceSidebarModel.sections(
            in: snapshot,
            tmuxSessionVisibility: .init(hideKwtManagedSessions: false),
            connectedTmuxSessionIDs: [defaultSelection.id, kwtSelection.id],
            liveTmuxWindowCounts: [defaultSelection.id: 2, kwtSelection.id: 5]
        )[0]
        #expect(Set(all.sessionRows(for: .tmux).map(\.target)) == [
            .tmuxSession(hostID: hostID, name: "desk"),
            .tmuxSession(hostID: hostID, name: "desk", socketName: "kwt"),
        ])
        #expect(all.sessionRows(for: .tmux).first { $0.target == .tmuxSession(
            hostID: hostID,
            name: "desk",
            socketName: "kwt"
        ) }?.subtitle == "5 windows")
        #expect(all.projects[0].worktreeRows[0].worktreeStatus?.tmuxWindowCount == 5)
        #expect(WorkspaceSidebarModel.canRequestKill(kwtSelection, in: snapshot))
        snapshot.hosts[0].tmuxSessions.removeAll { $0.socketName == "kwt" }
        #expect(!WorkspaceSidebarModel.canRequestKill(kwtSelection, in: snapshot))
        #expect(WorkspaceSidebarModel.canRequestKill(defaultSelection, in: snapshot))

        snapshot.hosts[0].tmuxSessions = sessions
        snapshot.worktrees = []
        snapshot.directoryWorkspaces = [.init(
            id: UUID(),
            hostID: hostID,
            name: "desk",
            path: "/workspaces/desk",
            tmuxSessionName: "desk",
            tmuxSocketName: "kwt",
            tmuxAttachMode: .direct,
            sessionLive: true
        )]
        #expect(WorkspaceSidebarModel.sections(in: snapshot)[0].sessionRows(for: .tmux)
            .map(\.target) == [.tmuxSession(
                hostID: hostID,
                name: "desk"
            )])
    }

    @Test("direct named directory workspaces use endpoint liveness")
    func directNamedDirectoryWorkspaceUsesEndpointLiveness() {
        let hostID = UUID()
        let workspace = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: hostID,
            name: "jibot",
            path: "/workspaces/jibot",
            tmuxSessionName: "kwt-workspace-dir-jibot-abc",
            tmuxSocketName: "kwt",
            tmuxAttachMode: .direct,
            sessionLive: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: [],
            worktrees: [],
            directoryWorkspaces: [workspace]
        )

        let row = WorkspaceSidebarModel.sections(in: snapshot)[0]
            .directoryWorkspaceRows[0]
        #expect(row.sessionIsRunning)

        let selection = WorkspaceSidebarModel.tmuxSessionSelection(
            for: workspace
        )
        #expect(WorkspaceSidebarModel.canRequestKill(selection, in: snapshot))
        var staleSelection = selection
        staleSelection.workspacePath = "/workspaces/replacement"
        #expect(!WorkspaceSidebarModel.canRequestKill(
            staleSelection,
            in: snapshot
        ))

        var stopped = snapshot
        stopped.directoryWorkspaces[0].sessionLive = false
        stopped.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: workspace.tmuxSessionName,
                managed: false,
                windows: [],
                serverPID: "123",
                sessionID: "$1",
                createdAt: "456"
            ),
        ]
        let stoppedRow = WorkspaceSidebarModel.sections(in: stopped)[0]
            .directoryWorkspaceRows[0]
        #expect(!stoppedRow.sessionIsRunning)
        #expect(!WorkspaceSidebarModel.canRequestKill(selection, in: stopped))
    }

    @Test("direct named worktree kill uses exact KWT ownership")
    func directNamedWorktreeKillUsesExactOwnership() throws {
        let hostID = UUID()
        let projectID = UUID()
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: projectID,
            name: "jibot",
            path: "/worktrees/jibot",
            branch: "main"
        )
        worktree.generation = "0123456789abcdef0123456789abcdef"
        worktree.tmuxSessionName = "kwt-worktree-jibot-abc"
        worktree.tmuxSocketName = "kwt"
        worktree.tmuxAttachMode = .direct
        var snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [.fixture(id: projectID, hostID: hostID)],
            worktrees: [worktree]
        )
        snapshot.hosts[0].tmuxSessions = [
            TmuxSessionSummary(
                name: "kwt-worktree-jibot-abc",
                managed: false,
                windows: [],
                serverPID: "123",
                sessionID: "$1",
                createdAt: "456"
            ),
        ]
        let selection = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )

        #expect(WorkspaceSidebarModel.canRequestKill(selection, in: snapshot))

        snapshot.worktrees = []
        #expect(!WorkspaceSidebarModel.canRequestKill(selection, in: snapshot))
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

        #expect(sections[0].sessionRows(for: .tmux).map(\.title) == ["homelab"])
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
            sections[0].sessionRows(for: .tmux).map(\.title) == ["kwt-docbank-pr-32"]
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
