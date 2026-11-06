import Foundation
@testable import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

extension WorkspaceTmuxDiscoveryTests {
    @MainActor
    @Test("viewing a session in the key window acknowledges only its finished turn")
    func viewingAcknowledgesFinishedTurn() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let store = SceneTmuxSurfaceStoreStub()
        let defaults = try #require(UserDefaults(
            suiteName: "ghosthub-agent-attention-\(UUID().uuidString)"
        ))
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                .success([
                    agentSession("anchor", "$1", [
                        TmuxPaneAgentState(paneID: "%1", state: .done, stamp: 300, agent: "codex"),
                    ]),
                    agentSession("desk", "$2", [
                        TmuxPaneAgentState(paneID: "%2", state: .done, stamp: 200, agent: "claude"),
                        TmuxPaneAgentState(
                            paneID: "%3",
                            state: .approval,
                            stamp: 150,
                            agent: "gemini"
                        ),
                    ]),
                ])
            }
        )
        let attention = AgentAttentionStore(userDefaults: defaults)
        model.agentAttentionStore = attention
        func current(_ name: String) -> AgentAttention? {
            attention.attentionByEndpoint(in: model.snapshot)[
                AgentAttentionStore.endpointKey(hostID: hostID, name: name, socketName: nil)
            ]
        }
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 2
        }

        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        model.openBorrowedTmuxSession(desk)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return store.requestCount > 0 && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(current("desk") == .approval(agent: "gemini"))
        #expect(attention.acknowledgedDoneStamps.isEmpty, "an unfocused window is not seen")

        model.isFocusedWindow = true

        #expect(attention.acknowledgedDoneStamps.values.sorted() == [200])
        #expect(current("desk") == .approval(agent: "gemini"), "a pending approval keeps its dot")
        #expect(current("anchor") == .finished(agent: "codex"))
        #expect(
            AgentAttentionStore(userDefaults: defaults).acknowledgedDoneStamps
                == attention.acknowledgedDoneStamps,
            "acknowledgements survive relaunch"
        )

        store.returnsSurface = false
        let anchor = WorkspaceTmuxSessionSelection(hostID: hostID, name: "anchor")
        model.openBorrowedTmuxSession(anchor)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return store.requestCount > 1
        }

        #expect(model.activeBorrowedTmuxSelection == anchor)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(
            current("anchor") == .finished(agent: "codex"),
            "a session that never connected is not seen"
        )
        #expect(attention.acknowledgedDoneStamps.values.sorted() == [200])
    }

    @MainActor
    @Test("returning to a retained connected session acknowledges its finished turn")
    func returningToRetainedSessionAcknowledges() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let store = SceneTmuxSurfaceStoreStub()
        let defaults = try #require(UserDefaults(
            suiteName: "ghosthub-agent-attention-\(UUID().uuidString)"
        ))
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                .success([
                    agentSession("anchor", "$1", [
                        TmuxPaneAgentState(paneID: "%1", state: .done, stamp: 300, agent: "codex"),
                    ]),
                    agentSession("desk", "$2", [
                        TmuxPaneAgentState(paneID: "%2", state: .done, stamp: 200, agent: "claude"),
                    ]),
                ])
            }
        )
        let attention = AgentAttentionStore(userDefaults: defaults)
        model.agentAttentionStore = attention
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 2
        }
        func open(_ name: String) async {
            model.openBorrowedTmuxSession(
                WorkspaceTmuxSessionSelection(hostID: hostID, name: name)
            )
            await waitUntilMainActor {
                model.prepareActiveBorrowedTmuxSurface()
                return model.activeBorrowedTmuxSelection?.name == name
                    && model.activeBorrowedTmuxSessionIsConnected
            }
        }
        await open("anchor")
        await open("desk")
        model.isFocusedWindow = true
        #expect(attention.acknowledgedDoneStamps.values.sorted() == [200])

        await open("anchor")

        #expect(store.requestCount == 2, "anchor reused its retained client")
        #expect(attention.acknowledgedDoneStamps.values.sorted() == [200, 300])
    }
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
