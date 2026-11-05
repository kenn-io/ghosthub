import Foundation
import GhosthubWorkspace
import Testing

@Suite("Agent attention")
struct AgentAttentionTests {
    @Test("parses values written by kwt agent-hook", arguments: [
        ("done 1800000000 claude", AgentHookState.done, 1_800_000_000, "claude"),
        ("approval 17 codex", AgentHookState.approval, 17, "codex"),
    ])
    func parsesHookValue(value: String, state: AgentHookState, stamp: Int, agent: String) {
        #expect(
            TmuxPaneAgentState(paneID: "%3", optionValue: value)
                == TmuxPaneAgentState(paneID: "%3", state: state, stamp: stamp, agent: agent)
        )
    }

    @Test("ignores values the hook would not write", arguments: [
        "", "done", "done 12", "sleeping 12 claude", "done soon claude", "done 0 claude",
        "done 12 claude extra",
    ])
    func rejectsForeignValue(value: String) {
        #expect(TmuxPaneAgentState(paneID: "%3", optionValue: value) == nil)
    }

    @Test("a pending approval or question outranks a finished turn and survives acknowledgement")
    func blockedPanesAlwaysShow() {
        let session = summary([
            pane("%1", .done, 300, "claude"),
            pane("%2", .input, 100, "codex"),
            pane("%3", .approval, 50, "gemini"),
        ])

        #expect(session.agentAttention(acknowledgedDoneStamp: 999) == .approval(agent: "gemini"))
        #expect(
            summary([pane("%2", .input, 100, "codex"), pane("%1", .done, 300, "claude")])
                .agentAttention(acknowledgedDoneStamp: 999) == .input(agent: "codex")
        )
    }

    @Test("a finished turn shows until a stamp at least as new is acknowledged")
    func finishedTurnAcknowledgement() {
        let session = summary([
            pane("%1", .done, 200, "claude"),
            pane("%2", .working, 250, "codex"),
        ])

        #expect(session.agentAttention(acknowledgedDoneStamp: nil) == .finished(agent: "claude"))
        #expect(session.agentAttention(acknowledgedDoneStamp: 199) == .finished(agent: "claude"))
        #expect(session.agentAttention(acknowledgedDoneStamp: 200) == nil)
        #expect(session.latestAgentDoneStamp == 200)
        #expect(summary([pane("%2", .working, 250, "codex")])
            .agentAttention(acknowledgedDoneStamp: nil) == nil)
    }

    @Test("a replacement session with the same name has its own acknowledgement key")
    func acknowledgementKeyTracksIdentity() {
        let host = UUID()
        var original = summary([])
        original.sessionID = "$1"
        original.createdAt = "100"
        var replacement = original
        replacement.sessionID = "$2"
        replacement.createdAt = "200"

        #expect(original.agentAttentionKey(hostID: host) != replacement
            .agentAttentionKey(hostID: host))
        #expect(original.agentAttentionKey(hostID: host) == original
            .agentAttentionKey(hostID: host))
    }

    @Test("labels name the agent and the reason")
    func labels() {
        #expect(AgentAttention.approval(agent: "claude").label == "Claude needs approval")
        #expect(AgentAttention.input(agent: "codex").label == "Codex is waiting for input")
        #expect(AgentAttention.finished(agent: "muse").label == "Muse finished")
    }

    private func summary(_ panes: [TmuxPaneAgentState]) -> TmuxSessionSummary {
        TmuxSessionSummary(
            name: "desk", socketName: "kwt", managed: false, windows: [],
            serverPID: "10", sessionID: "$1", createdAt: "100", agentPanes: panes
        )
    }

    private func pane(
        _ id: String, _ state: AgentHookState, _ stamp: Int, _ agent: String
    ) -> TmuxPaneAgentState {
        TmuxPaneAgentState(paneID: id, state: state, stamp: stamp, agent: agent)
    }
}
