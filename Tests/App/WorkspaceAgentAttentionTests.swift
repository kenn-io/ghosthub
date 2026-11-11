import Foundation
import GhosthubTmux
@testable import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

extension WorkspaceTmuxDiscoveryTests {
    @MainActor
    @Test("viewing a session in the key window acknowledges only its finished turn")
    func viewingAcknowledgesFinishedTurn() async throws {
        let fixture = try AttentionFixture(sessions: [
            agentSession("anchor", "$1", [
                TmuxPaneAgentState(paneID: "%1", state: .done, stamp: 300, agent: "codex"),
            ]),
            agentSession("desk", "$2", [
                TmuxPaneAgentState(paneID: "%2", state: .done, stamp: 200, agent: "claude"),
                TmuxPaneAgentState(paneID: "%3", state: .approval, stamp: 150, agent: "gemini"),
            ]),
        ])
        let model = fixture.model
        let attention = fixture.attention
        await fixture.discover()

        await fixture.open("desk", attachedTo: "$2")
        #expect(fixture.current("desk") == .approval(agent: "gemini"))
        #expect(attention.acknowledgedDoneStamps.isEmpty, "an unfocused window is not seen")

        model.isFocusedWindow = true

        await waitUntilMainActor { attention.acknowledgedDoneStamps.values.sorted() == [200] }
        #expect(
            fixture.current("desk") == .approval(agent: "gemini"),
            "a pending approval keeps its badge"
        )
        #expect(fixture.current("anchor") == .finished(agent: "codex"))
        #expect(
            AgentAttentionStore(userDefaults: fixture.defaults).acknowledgedDoneStamps
                == attention.acknowledgedDoneStamps,
            "acknowledgements survive relaunch"
        )

        fixture.store.returnsSurface = false
        let anchor = WorkspaceTmuxSessionSelection(hostID: fixture.hostID, name: "anchor")
        model.openBorrowedTmuxSession(anchor)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return fixture.store.requestCount > 1
        }

        #expect(model.activeBorrowedTmuxSelection == anchor)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(
            fixture.current("anchor") == .finished(agent: "codex"),
            "a session that never connected is not seen"
        )
        #expect(attention.acknowledgedDoneStamps.values.sorted() == [200])
    }

    @MainActor
    @Test("returning to a retained connected session acknowledges its finished turn")
    func returningToRetainedSessionAcknowledges() async throws {
        let fixture = try AttentionFixture(sessions: [
            agentSession("anchor", "$1", [
                TmuxPaneAgentState(paneID: "%1", state: .done, stamp: 300, agent: "codex"),
            ]),
            agentSession("desk", "$2", [
                TmuxPaneAgentState(paneID: "%2", state: .done, stamp: 200, agent: "claude"),
            ]),
        ])
        await fixture.discover()
        await fixture.open("anchor", attachedTo: "$1")
        await fixture.open("desk", attachedTo: "$2")
        fixture.model.isFocusedWindow = true
        await waitUntilMainActor {
            fixture.attention.acknowledgedDoneStamps.values.sorted() == [200]
        }

        await fixture.open("anchor", attachedTo: "$1")

        #expect(fixture.store.requestCount == 2, "anchor reused its retained client")
        await waitUntilMainActor {
            fixture.attention.acknowledgedDoneStamps.values.sorted() == [200, 300]
        }
    }

    @MainActor
    @Test("a finished turn waits for the attached session to be verified")
    func acknowledgementWaitsForAttachedIdentity() async throws {
        let fixture = try AttentionFixture(sessions: [
            agentSession("desk", "$2", [
                TmuxPaneAgentState(paneID: "%2", state: .done, stamp: 200, agent: "claude"),
            ]),
        ])
        await fixture.discover()
        fixture.model.isFocusedWindow = true

        await fixture.open("desk", attachedTo: nil)
        #expect(fixture.attention.acknowledgedDoneStamps.isEmpty, "connected but not yet verified")

        fixture.newestClientShows("$2")
        await waitUntilMainActor {
            fixture.attention.acknowledgedDoneStamps.values.sorted() == [200]
        }
    }

    @MainActor
    @Test("a new session that reuses a renamed session's name is not acknowledged")
    func nameReuseIsNotAcknowledged() async throws {
        let fixture = try AttentionFixture(sessions: [agentSession("desk", "$2", [])])
        await fixture.discover()
        fixture.model.isFocusedWindow = true
        await fixture.open("desk", attachedTo: "$2")

        // Outside Ghosthub, the attached session is renamed and a new
        // session takes its old name. Both agents finish a turn.
        await fixture.refresh([
            agentSession("desk-old", "$2", [
                TmuxPaneAgentState(paneID: "%2", state: .done, stamp: 250, agent: "codex"),
            ]),
            agentSession("desk", "$5", [
                TmuxPaneAgentState(paneID: "%5", state: .done, stamp: 200, agent: "claude"),
            ]),
        ])

        await waitUntilMainActor {
            fixture.attention.acknowledgedDoneStamps.values.sorted() == [250]
        }
        #expect(fixture.current("desk") == .finished(agent: "claude"))
    }

    @MainActor
    @Test("switching sessions inside tmux acknowledges the session the client shows")
    func tmuxSessionSwitchAcknowledgesShownSession() async throws {
        let fixture = try AttentionFixture(sessions: [
            agentSession("anchor", "$1", []),
            agentSession("desk", "$2", []),
        ])
        await fixture.discover()
        fixture.model.isFocusedWindow = true
        await fixture.open("desk", attachedTo: "$2")

        // The user switches the client to anchor with tmux's own keys.
        fixture.newestClientShows("$1")
        await fixture.refresh([
            agentSession("anchor", "$1", [
                TmuxPaneAgentState(paneID: "%1", state: .done, stamp: 300, agent: "codex"),
            ]),
            agentSession("desk", "$2", [
                TmuxPaneAgentState(paneID: "%2", state: .done, stamp: 400, agent: "claude"),
            ]),
        ])

        await waitUntilMainActor {
            fixture.attention.acknowledgedDoneStamps.values.sorted() == [300]
        }
        #expect(fixture.current("desk") == .finished(agent: "claude"))
    }
}

extension WorkspaceTmuxDiscoveryTests {
    @MainActor
    @Test("switching inside tmux from a quiet session follows the shown session")
    func tmuxSessionSwitchFromQuietSession() async throws {
        let fixture = try AttentionFixture(sessions: [
            agentSession("anchor", "$1", []),
            agentSession("desk", "$2", []),
        ])
        await fixture.discover()
        await fixture.open("anchor", attachedTo: "$1")
        await waitUntilMainActor { fixture.model.shownTmuxSession?.name == "anchor" }

        // The user switches the client to desk with tmux's own keys, and
        // desk's agent then asks for approval while the window is behind.
        fixture.newestClientShows("$2")
        await fixture.refresh([
            agentSession("anchor", "$1", []),
            agentSession("desk", "$2", [
                TmuxPaneAgentState(paneID: "%2", state: .approval, stamp: 300, agent: "claude"),
            ]),
        ])
        await waitUntilMainActor { fixture.model.shownTmuxSession?.name == "desk" }
        #expect(fixture.model.activeBorrowedTmuxSelection?.name == "anchor")

        // The agent finishes; viewing the window marks desk's turn seen.
        await fixture.refresh([
            agentSession("anchor", "$1", []),
            agentSession("desk", "$2", [
                TmuxPaneAgentState(paneID: "%2", state: .done, stamp: 400, agent: "claude"),
            ]),
        ])
        fixture.model.isFocusedWindow = true
        await waitUntilMainActor {
            fixture.attention.acknowledgedDoneStamps.values.sorted() == [400]
        }
    }

    @MainActor
    @Test("a tmux answer that predates an inventory refresh does not mark a turn seen")
    func staleShownSessionAnswerIsDiscarded() async throws {
        let fixture = try AttentionFixture(sessions: [
            agentSession("anchor", "$1", []),
            agentSession("desk", "$2", []),
        ])
        await fixture.discover()
        await fixture.open("anchor", attachedTo: "$1")
        await waitUntilMainActor { fixture.model.shownTmuxSession?.name == "anchor" }

        // Focusing the window asks tmux what the client shows; tmux answers
        // "anchor" but the reply is slow to arrive.
        let gate = DispatchSemaphore(value: 0)
        fixture.identityGate.store(gate)
        fixture.model.isFocusedWindow = true
        await waitUntilMainActor { fixture.heldIdentityReplies.load() > 0 }

        // Meanwhile the user switches the client to desk, and anchor's
        // agent then finishes a turn the user has not seen.
        fixture.newestClientShows("$2")
        await fixture.refresh([
            agentSession("anchor", "$1", [
                TmuxPaneAgentState(paneID: "%1", state: .done, stamp: 300, agent: "codex"),
            ]),
            agentSession("desk", "$2", []),
        ])
        fixture.identityGate.store(nil)
        gate.signal()

        await waitUntilMainActor { fixture.model.shownTmuxSession?.name == "desk" }
        #expect(fixture.attention.acknowledgedDoneStamps.isEmpty)
        #expect(fixture.current("anchor") == .finished(agent: "codex"))
    }
}

@MainActor
private struct AttentionFixture {
    let hostID: UUID
    let store = SceneTmuxSurfaceStoreStub()
    let defaults: UserDefaults
    let attention: AgentAttentionStore
    let model: WorkspaceSceneModel
    /// Session each client reports, by launch order; a missing entry keeps
    /// that client unverified. Clients answer separately, so a late reply
    /// from an earlier client never reports a later client's session.
    let clientSessionIDs = LockedValue<[Int: String]>([:])
    let identityReplies = LockedValue(0)
    /// While set, identity replies wait on it after reading the session.
    let identityGate = LockedValue<DispatchSemaphore?>(nil)
    let heldIdentityReplies = LockedValue(0)
    private let sessions: LockedValue<[DiscoveredTmuxSession]>

    init(sessions: [DiscoveredTmuxSession]) throws {
        let environment = try setupStandardEnvironment()
        hostID = environment.host.id
        defaults = try #require(UserDefaults(
            suiteName: "ghosthub-agent-attention-\(UUID().uuidString)"
        ))
        let clientSessionIDs = clientSessionIDs
        let launchCommands = store.launchCommands
        let identityReplies = identityReplies
        let identityGate = identityGate
        let heldIdentityReplies = heldIdentityReplies
        let sessions = LockedValue(sessions)
        self.sessions = sessions
        model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: TmuxPaneSplitter { _, _, command in
                guard command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"),
                      let client = launchIndex(
                          ofClientProbedBy: command,
                          launches: launchCommands.load()
                      ),
                      let sessionID = clientSessionIDs.load()[client]
                else { return (0, "") }
                identityReplies.withLock { $0 += 1 }
                if let gate = identityGate.load() {
                    heldIdentityReplies.withLock { $0 += 1 }
                    gate.wait()
                }
                return (
                    0,
                    "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t101\t789\t321"
                        + "\t/dev/ttys001\t\(sessionID)\t1000\t%9\n"
                )
            },
            tmuxSessionDiscovery: { _ in .success(sessions.load()) }
        )
        attention = AgentAttentionStore(userDefaults: defaults)
        model.agentAttentionStore = attention
    }

    func discover() async {
        model.startTmuxSessionDiscovery()
        await waitForInventory()
    }

    /// Replaces the discovered sessions and waits for the snapshot to match.
    func refresh(_ updated: [DiscoveredTmuxSession]) async {
        sessions.store(updated)
        model.refreshTmuxSessionDiscovery()
        await waitForInventory()
    }

    private func waitForInventory() async {
        let expected = inventoryShape(sessions.load().map { ($0.name, $0.agentPanes) })
        await waitUntilMainActor {
            let current = model.snapshot.hosts[0].tmuxSessions
            return inventoryShape(current.map { ($0.name, $0.agentPanes) }) == expected
        }
    }

    /// Opens `name`. A client launched for it reports `sessionID`.
    func open(_ name: String, attachedTo sessionID: String?) async {
        let nextClient = store.launchCommands.load().count
        clientSessionIDs.withLock { $0[nextClient] = sessionID }
        model.openBorrowedTmuxSession(
            WorkspaceTmuxSessionSelection(hostID: hostID, name: name)
        )
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSelection?.name == name
                && model.activeBorrowedTmuxSessionIsConnected
        }
    }

    /// The newest client now shows `sessionID`, as after tmux's own
    /// session-switch keys.
    func newestClientShows(_ sessionID: String) {
        let newest = store.launchCommands.load().count - 1
        clientSessionIDs.withLock { $0[newest] = sessionID }
    }

    func current(_ name: String) -> AgentAttention? {
        attention.attentionByEndpoint(in: model.snapshot)[
            AgentAttentionStore.endpointKey(hostID: hostID, name: name, socketName: nil)
        ]
    }
}

/// Launch order of the client an identity probe asks about. The probe reads
/// the client's tty from a file named by the client's token, which the
/// client's launch command also carries.
private func launchIndex(
    ofClientProbedBy command: String,
    launches: [String]
) -> Int? {
    let token = /([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})['"]? 2>\/dev\/null/
    guard let match = command.firstMatch(of: token) else { return nil }
    return launches.firstIndex { $0.contains(String(match.1)) }
}

/// Session names with their agent states, for comparing inventories.
private func inventoryShape(_ sessions: [(String, [TmuxPaneAgentState])]) -> [String] {
    sessions.map { name, panes in
        ([name] + panes.map { "\($0.state.rawValue):\($0.stamp)" }).joined(separator: " ")
    }.sorted()
}

private func agentSession(
    _ name: String,
    _ sessionID: String,
    _ panes: [TmuxPaneAgentState]
) -> DiscoveredTmuxSession {
    var session = DiscoveredTmuxSession(
        name: name,
        windowCount: 1,
        serverPID: "101",
        sessionID: sessionID,
        createdAt: "1000",
        managed: false
    )
    session.agentPanes = panes
    return session
}
