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

        fixture.attachedSessionID.store("$2")
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
        fixture.attachedSessionID.store("$1")
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

@MainActor
private struct AttentionFixture {
    let hostID: UUID
    let store = SceneTmuxSurfaceStoreStub()
    let defaults: UserDefaults
    let attention: AgentAttentionStore
    let model: WorkspaceSceneModel
    /// Session the next attached client reports; nil keeps it unverified.
    let attachedSessionID = LockedValue<String?>(nil)
    let identityReplies = LockedValue(0)
    private let sessions: LockedValue<[DiscoveredTmuxSession]>

    init(sessions: [DiscoveredTmuxSession]) throws {
        let environment = try setupStandardEnvironment()
        hostID = environment.host.id
        defaults = try #require(UserDefaults(
            suiteName: "ghosthub-agent-attention-\(UUID().uuidString)"
        ))
        let attachedSessionID = attachedSessionID
        let identityReplies = identityReplies
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
                      let sessionID = attachedSessionID.load()
                else { return (0, "") }
                identityReplies.withLock { $0 += 1 }
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

    func open(_ name: String, attachedTo sessionID: String?) async {
        attachedSessionID.store(sessionID)
        model.openBorrowedTmuxSession(
            WorkspaceTmuxSessionSelection(hostID: hostID, name: name)
        )
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSelection?.name == name
                && model.activeBorrowedTmuxSessionIsConnected
        }
    }

    func current(_ name: String) -> AgentAttention? {
        attention.attentionByEndpoint(in: model.snapshot)[
            AgentAttentionStore.endpointKey(hostID: hostID, name: name, socketName: nil)
        ]
    }
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
