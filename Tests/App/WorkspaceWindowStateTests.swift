import Foundation
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private struct RestorationFixture {
    static let worktreeGeneration =
        "0123456789abcdef0123456789abcdef"

    let snapshot: WorkspaceSnapshot
    let selection: WorkspaceSelection
    let tmuxSelection: WorkspaceTmuxSessionSelection

    static func local(
        sessionName: String,
        socketName: String? = nil
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
                socketName: socketName
            )
        )
    }

    func reidentified() -> Self {
        Self.local(
            sessionName: tmuxSelection.name,
            socketName: tmuxSelection.socketName
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
    @Test("window state survives a temporarily nil scene binding")
    func windowStateSurvivesNilSceneBinding() {
        let fallback = WorkspaceWindowState.fresh()
        let restored = WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil
        )
        var buffer = WorkspaceWindowStateBuffer(retained: fallback)

        #expect(buffer.resolved(nil) == fallback)

        #expect(buffer.beginAppearance(with: nil) == nil)
        buffer.prepareToPresent(fallback)
        #expect(buffer.receive(fallback) == nil)

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
            socketName: "kwt-pr-0123456789abcdef"
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
            ) == .ready(selection: fixture.selection, tmux: nil)
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
            ) == .ready(selection: fixture.selection, tmux: nil)
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
            tmux: after.tmuxSelection
        ))
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
                    tmux: nil
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
            socketName: "kwt-pr-0123456789abcdef"
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
