import GhosthubTransport
import Foundation
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Workspace window titles")
struct WorkspaceWindowTitleTests {
    @Test("Custom titles trim and blank titles restore automatic naming")
    func normalization() {
        let state = WorkspaceWindowState.fresh()

        #expect(
            state.withCustomTitle("  Review logs  ").customTitle
                == "Review logs"
        )
        #expect(state.withCustomTitle(" \n ").customTitle == nil)
        #expect(state.customTitle == nil)
    }
}

private struct RestorationFixture {
    static let worktreeGeneration =
        "0123456789abcdef0123456789abcdef"

    let snapshot: WorkspaceSnapshot
    let selection: WorkspaceSelection
    let tmuxSelection: WorkspaceTmuxSessionSelection

    static func local(
        sessionName: String,
        socketName: String? = nil,
        tmuxAttachMode: TmuxAttachMode = .direct
    ) -> Self {
        let hostID = UUID()
        let projectID = UUID()
        let worktreeID = UUID()
        let projectKey = "github.com/kenn-io/ghosthub"
        let worktreeScopedKey = "worktree:pr-42"
        let snapshot = WorkspaceSnapshot(
            hosts: [
                HostSummary(
                    id: hostID,
                    configKey: "local",
                    name: "This Mac",
                    kind: .selfHost,
                    platform: .macOS,
                    preferredTransport: .local,
                    tmuxSessions: socketName == nil ? [
                        TmuxSessionSummary(
                            name: sessionName,
                            managed: false,
                            windows: []
                        ),
                    ] : [],
                    decodedConnectionState: .local
                ),
            ],
            projects: [
                ProjectSummary(
                    id: projectID,
                    hostID: hostID,
                    scopedKey: projectKey,
                    name: "Ghosthub",
                    rootPath: "/tmp/ghosthub"
                ),
            ],
            worktrees: [
                WorktreeSummary(
                    id: worktreeID,
                    hostID: hostID,
                    projectID: projectID,
                    scopedKey: worktreeScopedKey,
                    name: "pr-42",
                    path: "/tmp/ghosthub-pr-42",
                    branch: "pr-42",
                    generation: worktreeGeneration,
                    tmuxSessionName: sessionName,
                    tmuxSocketName: socketName,
                    tmuxAttachMode: tmuxAttachMode,
                    sessionBackend: .localTmux
                ),
            ]
        )
        return Self(
            snapshot: snapshot,
            selection: WorkspaceSelection(
                selectedHostID: hostID,
                selectedProjectID: projectID,
                selectedWorktreeID: worktreeID
            ),
            tmuxSelection: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: sessionName,
                worktreeID: worktreeID,
                worktreePath: "/tmp/ghosthub-pr-42",
                worktreeGeneration: worktreeGeneration,
                socketName: socketName,
                tmuxAttachMode: tmuxAttachMode
            )
        )
    }

    func reidentified() -> Self {
        Self.local(
            sessionName: tmuxSelection.name,
            socketName: tmuxSelection.socketName,
            tmuxAttachMode: tmuxSelection.tmuxAttachMode ?? .direct
        )
    }

    static let invalidStates = [
        WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: " ", projectKey: nil, worktreeGeneration: nil
            ),
            tmux: nil
        ),
        WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "local",
                projectKey: nil,
                worktreeGeneration: worktreeGeneration
            ),
            tmux: nil
        ),
        WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "local",
                projectKey: "github.com/kenn-io/ghosthub",
                worktreeGeneration: "not-a-generation"
            ),
            tmux: nil
        ),
        WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "local", projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: .init(
                hostKey: "remote",
                sessionName: "editor",
                socketName: nil,
                owner: .unbound
            )
        ),
        WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "local", projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: .init(
                hostKey: "local",
                sessionName: " ",
                socketName: nil,
                owner: .unbound
            )
        ),
        WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "local",
                projectKey: "github.com/kenn-io/ghosthub",
                worktreeGeneration: worktreeGeneration
            ),
            tmux: .init(
                hostKey: "local",
                sessionName: "editor",
                socketName: " ",
                owner: .worktree(generation: worktreeGeneration)
            )
        ),
        WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "local",
                projectKey: "github.com/kenn-io/ghosthub",
                worktreeGeneration: worktreeGeneration
            ),
            tmux: .init(
                hostKey: "local",
                sessionName: "editor",
                socketName: nil,
                owner: .unbound
            )
        ),
    ]
}

@Suite("Workspace window restoration state")
struct WorkspaceWindowStateTests {
    @Test("project tab plans preserve visible worktree order and endpoints")
    func projectTabPlanPreservesWorktreeOrder() throws {
        let fixture = RestorationFixture.local(sessionName: "main")
        let host = try #require(fixture.snapshot.hosts.first)
        let project = try #require(fixture.snapshot.projects.first)
        var first = try #require(fixture.snapshot.worktrees.first)
        first.tmuxSocketName = "protected-main"
        var second = first
        second = WorktreeSummary(
            id: UUID(),
            hostID: host.id,
            projectID: project.id,
            scopedKey: "worktree:feature",
            name: "feature",
            path: "/tmp/ghosthub-feature",
            branch: "feature",
            generation: "fedcba9876543210fedcba9876543210",
            tmuxSessionName: "feature",
            sessionBackend: .localTmux
        )
        let states = try #require(ProjectWorktreeWindowPlan.states(
            project: project,
            host: host,
            worktrees: [second, first]
        ))

        #expect(states.map(\.tmux?.sessionName) == ["feature", "main"])
        #expect(states.last?.tmux?.socketName == "protected-main")
    }

    @Test("project tab plans reject the entire invalid worktree list")
    func projectTabPlanRejectsPartialLaunches() throws {
        let fixture = RestorationFixture.local(sessionName: "main")
        let host = try #require(fixture.snapshot.hosts.first)
        let project = try #require(fixture.snapshot.projects.first)
        let valid = try #require(fixture.snapshot.worktrees.first)
        var stale = valid
        stale.isStale = true

        #expect(!ProjectWorktreeWindowPlan.isAvailable(
            project: project,
            host: host,
            worktrees: [valid, stale]
        ))
        #expect(ProjectWorktreeWindowPlan.states(
            project: project,
            host: host,
            worktrees: [valid, stale]
        ) == nil)
    }

    @Test("project tab launch intent establishes absent worktree sessions")
    func projectTabLaunchIntentEstablishesAbsentSession() throws {
        let fixture = RestorationFixture.local(sessionName: "main")
        var snapshot = fixture.snapshot
        snapshot.hosts[0].tmuxSessions = []
        let host = try #require(snapshot.hosts.first)
        let project = try #require(snapshot.projects.first)
        let worktree = try #require(snapshot.worktrees.first)
        let states = try #require(ProjectWorktreeWindowPlan.states(
            project: project,
            host: host,
            worktrees: [worktree]
        ))
        let state = try #require(states.first)

        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: snapshot
            ) == .pending(selection: fixture.selection)
        )

        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: snapshot,
                launchIntent: .openWorktree
            ) == .ready(
                selection: fixture.selection,
                presentation: .tmux(fixture.tmuxSelection)
            )
        )

        let encoded = try JSONEncoder().encode(state)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        #expect(object["launchIntent"] == nil)
        object["launchIntent"] = "openWorktree"
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(
            WorkspaceWindowState.self,
            from: legacyData
        )
        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                restored,
                in: snapshot
            ) == .pending(selection: fixture.selection)
        )
    }

    @Test("older window descriptors decode without a directory path")
    func decodesOlderDescriptor() throws {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: fixture.tmuxSelection,
            snapshot: fixture.snapshot
        )
        let encoded = try JSONEncoder().encode(state)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        var navigation = try #require(
            object["navigation"] as? [String: Any]
        )
        navigation.removeValue(forKey: "directoryWorkspacePath")
        object["navigation"] = navigation
        let legacy = try JSONSerialization.data(withJSONObject: object)

        #expect(try JSONDecoder().decode(
            WorkspaceWindowState.self,
            from: legacy
        ) == state)
    }

    @Test("Herdr descriptor round-trips through scene state")
    func herdrDescriptorRoundTrips() throws {
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil,
            herdr: WorkspaceHerdrDescriptor(
                hostKey: "local",
                sessionName: "editor"
            )
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            WorkspaceWindowState.self,
            from: encoded
        )

        #expect(decoded == state)
        #expect(decoded.herdr?.sessionName == "editor")
    }

    @Test("Zellij descriptor round-trips through scene state")
    func zellijDescriptorRoundTrips() throws {
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil,
            zellij: WorkspaceZellijDescriptor(
                hostKey: "local",
                sessionName: "editor"
            )
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            WorkspaceWindowState.self,
            from: encoded
        )

        #expect(decoded == state)
        #expect(decoded.zellij?.sessionName == "editor")
    }

    @Test("invalid Herdr descriptors are rejected")
    func invalidHerdrDescriptorsAreRejected() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let invalid = [
            WorkspaceHerdrDescriptor(hostKey: "local", sessionName: " "),
            WorkspaceHerdrDescriptor(hostKey: " ", sessionName: "editor"),
            WorkspaceHerdrDescriptor(hostKey: "remote", sessionName: "editor"),
        ]

        for descriptor in invalid {
            let state = WorkspaceWindowState(
                windowID: UUID(),
                navigation: WorkspaceNavigationDescriptor(
                    hostKey: "local",
                    projectKey: nil,
                    worktreeGeneration: nil
                ),
                tmux: nil,
                herdr: descriptor
            )
            #expect(
                WorkspaceWindowRestorationResolver.resolve(
                    state,
                    in: fixture.snapshot,
                    herdrFreshHostIDs: [fixture.selection.selectedHostID]
                ) == .invalid
            )
        }
    }

    @Test("capture persists Herdr only beside matching host navigation")
    func captureValidatesHerdrNavigation() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let hostID = fixture.selection.selectedHostID
        let otherHostID = UUID()
        var snapshot = fixture.snapshot
        snapshot.hosts.append(HostSummary(
            id: otherHostID,
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "builder.example.test"
        ))
        let hostOnly = WorkspaceSelection(selectedHostID: hostID)
        let activeHerdr = WorkspaceHerdrSessionSelection(
            hostID: hostID,
            name: "editor"
        )

        let valid = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: hostOnly,
            activeTmux: nil,
            activeHerdr: activeHerdr,
            snapshot: snapshot
        )
        let belowHost = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: nil,
            activeHerdr: activeHerdr,
            snapshot: snapshot
        )
        let mismatchedHost = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: hostOnly,
            activeTmux: nil,
            activeHerdr: WorkspaceHerdrSessionSelection(
                hostID: otherHostID,
                name: "editor"
            ),
            snapshot: snapshot
        )

        #expect(valid.herdr == WorkspaceHerdrDescriptor(
            hostKey: "local",
            sessionName: "editor"
        ))
        #expect(valid.tmux == nil)
        #expect(belowHost.navigation?.projectKey != nil)
        #expect(belowHost.herdr == nil)
        #expect(mismatchedHost.navigation?.hostKey == "local")
        #expect(mismatchedHost.herdr == nil)
    }

    @Test("directory navigation never captures or restores Herdr")
    func directoryNavigationRejectsHerdr() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let hostID = fixture.selection.selectedHostID
        let directoryID = UUID()
        var snapshot = fixture.snapshot
        snapshot.directoryWorkspaces = [DirectoryWorkspaceSummary(
            id: directoryID,
            hostID: hostID,
            name: "review",
            path: "/workspaces/review",
            tmuxSessionName: "review",
            sessionLive: true
        )]
        let selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedDirectoryWorkspaceID: directoryID
        )
        let activeHerdr = WorkspaceHerdrSessionSelection(
            hostID: hostID,
            name: "editor"
        )

        let captured = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: selection,
            activeTmux: nil,
            activeHerdr: activeHerdr,
            snapshot: snapshot
        )
        let contradictory = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                directoryWorkspacePath: "/workspaces/review"
            ),
            tmux: nil,
            herdr: WorkspaceHerdrDescriptor(
                hostKey: "local",
                sessionName: "editor"
            )
        )

        #expect(captured.herdr == nil)
        #expect(WorkspaceWindowRestorationResolver.resolve(
            contradictory,
            in: snapshot,
            herdrFreshHostIDs: [hostID]
        ) == .invalid)
    }

    @Test("capture refuses contradictory native presentations")
    func captureRefusesContradictoryPresentations() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let hostID = fixture.selection.selectedHostID
        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: WorkspaceSelection(selectedHostID: hostID),
            activeTmux: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "editor"
            ),
            activeHerdr: WorkspaceHerdrSessionSelection(
                hostID: hostID,
                name: "review"
            ),
            snapshot: fixture.snapshot
        )

        #expect(state.navigation?.hostKey == "local")
        #expect(state.tmux == nil)
        #expect(state.herdr == nil)
    }

    @Test("Herdr restoration requires fresh exact inventory")
    func herdrRestorationRequiresFreshExactInventory() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let hostID = fixture.selection.selectedHostID
        var snapshot = fixture.snapshot
        snapshot.hosts[0].herdrSessions = [
            HerdrSessionSummary(name: "editor", isDefault: false, state: .running),
        ]
        let selection = WorkspaceSelection(selectedHostID: hostID)
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil,
            herdr: WorkspaceHerdrDescriptor(
                hostKey: "local",
                sessionName: "editor"
            )
        )

        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: snapshot
            ) == .pending(selection: selection)
        )

        var absent = snapshot
        absent.hosts[0].herdrSessions = []
        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: absent,
                herdrFreshHostIDs: [hostID]
            ) == .pending(selection: selection)
        )

        var stopped = snapshot
        stopped.hosts[0].herdrSessions[0].state = .stopped
        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: stopped,
                herdrFreshHostIDs: [hostID]
            ) == .pending(selection: selection)
        )

        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: snapshot,
                herdrFreshHostIDs: [hostID]
            ) == .ready(
                selection: selection,
                presentation: .herdr(WorkspaceHerdrSessionSelection(
                    hostID: hostID,
                    name: "editor"
                ))
            )
        )
    }

    @Test("Zellij restoration requires fresh exact active inventory")
    func zellijRestorationRequiresFreshExactInventory() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let hostID = fixture.selection.selectedHostID
        var snapshot = fixture.snapshot
        snapshot.hosts[0].zellijSessions = [
            ZellijSessionSummary(name: "editor"),
        ]
        snapshot.hosts[0].zellijAvailable = true
        let selection = WorkspaceSelection(selectedHostID: hostID)
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil,
            zellij: WorkspaceZellijDescriptor(
                hostKey: "local",
                sessionName: "editor"
            )
        )

        #expect(WorkspaceWindowRestorationResolver.resolve(
            state,
            in: snapshot
        ) == .pending(selection: selection))

        #expect(WorkspaceWindowRestorationResolver.resolve(
            state,
            in: snapshot,
            zellijFreshHostIDs: [hostID]
        ) == .ready(
            selection: selection,
            presentation: .zellij(WorkspaceZellijSessionSelection(
                hostID: hostID,
                name: "editor"
            ))
        ))
    }

    @Test("same-ID stale update payloads are rewritten")
    func staleUpdatePayloadRequiresRewrite() {
        let windowID = UUID()
        let provisional = WorkspaceWindowState(
            windowID: windowID,
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                projectKey: "github.com/kenn-io/ghosthub",
                worktreeGeneration: nil
            ),
            tmux: WorkspaceTmuxDescriptor(
                hostKey: "local",
                sessionName: "editor",
                socketName: nil,
                owner: .unbound
            )
        )
        let stale = WorkspaceWindowState(
            windowID: windowID,
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "remote",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: WorkspaceTmuxDescriptor(
                hostKey: "remote",
                sessionName: "review",
                socketName: nil,
                owner: .unbound
            )
        )

        #expect(
            UpdateRelaunchStatePolicy.replacement(
                presented: stale,
                current: provisional
            ) == provisional
        )
    }

    @Test("generated fresh state preserves delayed native restoration")
    func generatedFreshStatePreservesDelayedNativeRestoration() {
        let generated = WorkspaceWindowState.fresh()
        let restored = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil
        )
        var buffer = WorkspaceWindowStateBuffer(retained: generated)

        #expect(buffer.resolved(nil) == generated)

        #expect(buffer.beginAppearance(with: nil) == nil)
        buffer.prepareToPresent(generated)
        #expect(buffer.receive(generated) == nil)

        #expect(buffer.receive(restored) == restored)

        #expect(buffer.resolved(nil) == restored)
    }

    enum OrdinaryOwnershipDrift: CaseIterable, Sendable {
        case sessionName
        case socket
    }

    @Test("capture stores stable keys and exact tmux identity")
    func captureUsesStableIdentity() {
        let fixture = RestorationFixture.local(
            sessionName: "kwt-ghosthub-main",
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected
        )
        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: fixture.tmuxSelection,
            snapshot: fixture.snapshot
        )

        #expect(state.navigation?.hostKey == "local")
        #expect(state.navigation?.projectKey == "github.com/kenn-io/ghosthub")
        #expect(
            state.navigation?.worktreeGeneration
                == RestorationFixture.worktreeGeneration
        )
        #expect(state.tmux?.sessionName == "kwt-ghosthub-main")
        #expect(state.tmux?.socketName == "kwt-pr-0123456789abcdef")
        #expect(
            state.tmux?.owner == .worktree(
                generation: RestorationFixture.worktreeGeneration
            )
        )
    }

    @Test("an unbound session beside worktree navigation keeps navigation only")
    func unboundSessionBesideWorktreeNavigationDropsTmux() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let unboundSession = WorkspaceTmuxSessionSelection(
            hostID: fixture.tmuxSelection.hostID,
            name: "docbank"
        )
        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: unboundSession,
            snapshot: fixture.snapshot
        )

        #expect(state.tmux == nil)
        #expect(
            state.navigation?.worktreeGeneration
                == RestorationFixture.worktreeGeneration
        )
        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: fixture.snapshot
            ) == .ready(
                selection: fixture.selection,
                presentation: nil
            )
        )
    }

    @Test("an unbound session persists only for host-level navigation")
    func unboundSessionPersistsOnlyAtHostLevel() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let unboundSession = WorkspaceTmuxSessionSelection(
            hostID: fixture.tmuxSelection.hostID,
            name: "docbank"
        )
        let hostOnly = WorkspaceSelection(
            selectedHostID: fixture.selection.selectedHostID
        )

        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: hostOnly,
            activeTmux: unboundSession,
            snapshot: fixture.snapshot
        )

        #expect(state.tmux?.sessionName == "docbank")
        #expect(state.tmux?.owner == .unbound)
    }

    enum UnboundOverlapNavigation: CaseIterable, Sendable {
        case project
        case generationlessWorktree
    }

    @Test(
        "navigating below host level drops a lingering unbound session",
        arguments: UnboundOverlapNavigation.allCases
    )
    func unboundSessionDroppedBelowHostLevel(
        _ navigation: UnboundOverlapNavigation
    ) {
        let fixture = RestorationFixture.local(sessionName: "editor")
        var snapshot = fixture.snapshot
        var selection = fixture.selection
        switch navigation {
        case .project:
            selection.selectedWorktreeID = nil
        case .generationlessWorktree:
            snapshot.worktrees[0].generation = nil
        }
        let unboundSession = WorkspaceTmuxSessionSelection(
            hostID: fixture.tmuxSelection.hostID,
            name: "docbank"
        )

        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: selection,
            activeTmux: unboundSession,
            snapshot: snapshot
        )

        #expect(state.tmux == nil)
        #expect(state.navigation?.projectKey != nil)
    }

    @Test("a session owned by another worktree keeps navigation only")
    func foreignWorktreeSessionBesideNavigationDropsTmux() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let foreignSession = WorkspaceTmuxSessionSelection(
            hostID: fixture.tmuxSelection.hostID,
            name: "other-editor",
            worktreeID: UUID(),
            worktreePath: "/tmp/ghosthub-other",
            worktreeGeneration: "fedcba9876543210fedcba9876543210"
        )
        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: foreignSession,
            snapshot: fixture.snapshot
        )

        #expect(state.tmux == nil)
        #expect(
            state.navigation?.worktreeGeneration
                == RestorationFixture.worktreeGeneration
        )
        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: fixture.snapshot
            ) == .ready(
                selection: fixture.selection,
                presentation: nil
            )
        )
    }

    @Test("stable keys resolve after runtime UUIDs change")
    func resolvesFreshRuntimeObjects() {
        let before = RestorationFixture.local(sessionName: "editor")
        let saved = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: before.selection,
            activeTmux: before.tmuxSelection,
            snapshot: before.snapshot
        )
        let after = before.reidentified()

        let result = WorkspaceWindowRestorationResolver.resolve(
            saved,
            in: after.snapshot
        )

        #expect(result == .ready(
            selection: after.selection,
            presentation: .tmux(after.tmuxSelection)
        ))
    }

    @Test("directory workspaces restore by host and path")
    func restoresDirectoryWorkspace() {
        let hostID = UUID()
        let directoryID = UUID()
        let sessionName = "kwt-workspace-dir-jibot-abc"
        let snapshot = WorkspaceSnapshot(
            hosts: [.init(
                id: hostID,
                configKey: "local",
                name: "This Mac",
                kind: .selfHost,
                platform: .macOS,
                preferredTransport: .local,
                tmuxSessions: [.init(
                    name: sessionName,
                    managed: true,
                    windows: []
                )],
                decodedConnectionState: .local
            )],
            projects: [],
            worktrees: [],
            directoryWorkspaces: [.init(
                id: directoryID,
                hostID: hostID,
                name: "jibot",
                path: "/workspaces/jibot",
                tmuxSessionName: sessionName,
                sessionLive: true
            )]
        )
        let selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedDirectoryWorkspaceID: directoryID
        )
        let tmux = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: sessionName,
            directoryWorkspaceID: directoryID,
            workspacePath: "/workspaces/jibot",
            tmuxAttachMode: .direct
        )

        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: selection,
            activeTmux: tmux,
            snapshot: snapshot
        )

        #expect(state.navigation?.projectKey == nil)
        #expect(
            state.navigation?.directoryWorkspacePath == "/workspaces/jibot"
        )
        #expect(
            state.tmux?.owner
                == .directoryWorkspace(path: "/workspaces/jibot")
        )
        #expect(
            WorkspaceWindowRestorationResolver.resolve(state, in: snapshot)
                == .ready(selection: selection, presentation: .tmux(tmux))
        )
    }

    @Test("same-path replacement does not inherit restored identity")
    func samePathReplacementStaysPending() {
        let before = RestorationFixture.local(sessionName: "editor")
        let saved = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: before.selection,
            activeTmux: before.tmuxSelection,
            snapshot: before.snapshot
        )
        let after = before.reidentified()
        var replacement = after.snapshot
        replacement.worktrees[0].generation =
            "fedcba9876543210fedcba9876543210"

        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                saved,
                in: replacement
            ) == .pending(
                selection: WorkspaceSelection(
                    selectedHostID: replacement.hosts[0].id,
                    selectedProjectID: replacement.projects[0].id
                )
            )
        )
    }

    @Test("active presentation keeps its observed generation after ID reuse")
    func activePresentationRejectsGenerationReplacement() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        var replacement = fixture.snapshot
        replacement.worktrees[0].generation =
            "fedcba9876543210fedcba9876543210"

        let saved = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: fixture.tmuxSelection,
            snapshot: replacement
        )

        #expect(
            saved.navigation?.worktreeGeneration
                == RestorationFixture.worktreeGeneration
        )
        #expect(
            saved.tmux?.owner == .worktree(
                generation: RestorationFixture.worktreeGeneration
            )
        )
        guard case .pending = WorkspaceWindowRestorationResolver.resolve(
            saved,
            in: replacement
        ) else {
            Issue.record("replacement generation must remain pending")
            return
        }
    }

    @Test("canonical generation enrichment changes captured window state")
    func generationEnrichmentRefreshesCaptureValue() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        var incomplete = fixture.snapshot
        incomplete.worktrees[0].generation = nil
        var unboundPresentation = fixture.tmuxSelection
        unboundPresentation.worktreeGeneration = nil
        let before = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: unboundPresentation,
            snapshot: incomplete
        )
        var enriched = incomplete
        enriched.worktrees[0].generation =
            RestorationFixture.worktreeGeneration

        let after = WorkspaceWindowState.capture(
            windowID: before.windowID,
            selection: fixture.selection,
            activeTmux: unboundPresentation,
            snapshot: enriched
        )

        #expect(before.navigation?.worktreeGeneration == nil)
        #expect(before.tmux == nil)
        #expect(
            after.navigation?.worktreeGeneration
                == RestorationFixture.worktreeGeneration
        )
        #expect(
            after.tmux?.owner == .worktree(
                generation: RestorationFixture.worktreeGeneration
            )
        )
        #expect(after != before)
    }

    @Test("missing durable worktree identity captures project only")
    func missingGenerationDropsWorktreeAndTmuxIdentity() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        var snapshot = fixture.snapshot
        snapshot.worktrees[0].generation = nil
        var activeTmux = fixture.tmuxSelection
        activeTmux.worktreeGeneration = nil
        let saved = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: activeTmux,
            snapshot: snapshot
        )

        #expect(
            WorkspaceWindowRestorationResolver.resolve(saved, in: snapshot)
                == .ready(
                    selection: WorkspaceSelection(
                        selectedHostID: snapshot.hosts[0].id,
                        selectedProjectID: snapshot.projects[0].id
                    ),
                    presentation: nil
                )
        )
    }

    @Test(
        "semantic invalid state is ignored without partial selection",
        arguments: RestorationFixture.invalidStates
    )
    func ignoresInvalidState(_ state: WorkspaceWindowState) {
        let fixture = RestorationFixture.local(sessionName: "editor")
        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: fixture.snapshot
            ) == .invalid
        )
    }

    @Test("unknown exact identities stay pending")
    func unknownIdentityStaysPending() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let state = WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "offline-host",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: .init(
                hostKey: "offline-host",
                sessionName: "editor",
                socketName: nil,
                owner: .unbound
            )
        )
        #expect(
            WorkspaceWindowRestorationResolver.resolve(
                state,
                in: fixture.snapshot
            ) == .pending(selection: nil)
        )
    }

    @Test("stale or conflicting ownership never retargets")
    func staleOwnershipStaysPending() {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: fixture.tmuxSelection,
            snapshot: fixture.snapshot
        )
        var changed = fixture.snapshot
        changed.worktrees[0].projectID = UUID()
        changed.hosts[0].tmuxSessions = [
            TmuxSessionSummary(name: "editor", managed: false, windows: []),
        ]

        #expect(
            WorkspaceWindowRestorationResolver.resolve(state, in: changed)
                == .pending(
                    selection: WorkspaceSelection(
                        selectedHostID: changed.hosts[0].id,
                        selectedProjectID: changed.projects[0].id
                    )
                )
        )
    }

    @Test("a named socket ignores a same-named default-server session")
    func namedSocketDoesNotFallBack() {
        let fixture = RestorationFixture.local(
            sessionName: "editor",
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected
        )
        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: fixture.tmuxSelection,
            snapshot: fixture.snapshot
        )
        var changed = fixture.snapshot
        changed.worktrees[0].tmuxSocketName = "different-socket"
        changed.hosts[0].tmuxSessions = [
            TmuxSessionSummary(name: "editor", managed: false, windows: []),
        ]

        guard case .pending = WorkspaceWindowRestorationResolver.resolve(
            state,
            in: changed
        ) else {
            Issue.record("named-socket restoration must stay pending")
            return
        }
    }

    @Test(
        "ordinary worktree restoration rejects changed tmux ownership",
        arguments: OrdinaryOwnershipDrift.allCases
    )
    func ordinaryWorktreeOwnershipMustStillMatch(
        _ drift: OrdinaryOwnershipDrift
    ) {
        let fixture = RestorationFixture.local(sessionName: "editor")
        let state = WorkspaceWindowState.capture(
            windowID: UUID(),
            selection: fixture.selection,
            activeTmux: fixture.tmuxSelection,
            snapshot: fixture.snapshot
        )
        var changed = fixture.snapshot
        switch drift {
        case .sessionName:
            changed.worktrees[0].tmuxSessionName = "renamed"
        case .socket:
            changed.worktrees[0].tmuxSocketName =
                "kwt-pr-0123456789abcdef"
        }

        guard case .pending = WorkspaceWindowRestorationResolver.resolve(
            state,
            in: changed
        ) else {
            Issue.record("changed worktree ownership must stay pending")
            return
        }
    }
}
