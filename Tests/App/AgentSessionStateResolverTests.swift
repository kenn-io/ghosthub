import Foundation
import Testing
import GhosthubWorkspace
@testable import GhosthubApp

private final class ResolverTestContext {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let worktreeID = UUID()
    let leafID = UUID()
    let sessionID = UUID()
    var recognizedAgents: [UUID: WorkspaceKnownAgent] = [:]

    func makeProcess(
        executable: String,
        agent: WorkspaceKnownAgent?,
        cpu: Double
    ) -> WorkspaceProcessResource {
        WorkspaceProcessResource(
            worktreeID: worktreeID,
            leafID: leafID,
            executableName: executable,
            recognizedAgent: agent,
            sample: WorkspaceResourceSample(
                cpuPercent: cpu,
                residentMB: 256,
                processCount: 1
            )
        )
    }

    func makeSession(
        outputOffset: TimeInterval = 0
    ) -> TerminalSessionSummary {
        TerminalSessionSummary(
            id: sessionID,
            hostID: UUID(),
            worktreeID: worktreeID,
            isAlive: true,
            lastOutputAt: now.addingTimeInterval(outputOffset)
        )
    }

    func resolve(
        processes: [WorkspaceProcessResource],
        sessions: [TerminalSessionSummary]
    ) -> WorkspaceAgentSessionState {
        let state = AgentSessionResolver.resolve(
            processes: processes,
            aliveSessions: sessions,
            leafSessionIDsByWorktreeID: [
                worktreeID: [leafID: sessionID],
            ],
            existingRecognizedAgentsBySessionID: recognizedAgents,
            now: now
        )
        recognizedAgents = state.recognizedAgentsBySessionID
        return state
    }
}

private func expectInactive(
    _ state: WorkspaceAgentSessionState,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        state.activeAgentLeafIDs.isEmpty,
        sourceLocation: sourceLocation
    )
    #expect(
        state.activeAgentWorktreeIDs.isEmpty,
        sourceLocation: sourceLocation
    )
    #expect(
        state.activeAgentByLeafID.isEmpty,
        sourceLocation: sourceLocation
    )
    #expect(
        state.currentRecognizedAgentSessionIDs.isEmpty,
        sourceLocation: sourceLocation
    )
}

struct AgentSessionResolverTests {
    private let ctx = ResolverTestContext()

    @Test("resolve keeps recognized agent sessions alive after the agent process exits")
    func resolveRetainsRecognizedSessionAcrossSamples() {
        let initial = ctx.resolve(
            processes: [
                ctx.makeProcess(
                    executable: "claude", agent: .claude, cpu: 12
                ),
            ],
            sessions: [ctx.makeSession()]
        )

        #expect(initial.recognizedAgentsBySessionID[ctx.sessionID] == .claude)
        #expect(initial.currentRecognizedAgentSessionIDs == Set([ctx.sessionID]))
        #expect(initial.agentSessionIDsByWorktreeID[ctx.worktreeID] == Set([ctx.sessionID]))
        #expect(initial.activeAgentLeafIDs == Set([ctx.leafID]))

        let followup = ctx.resolve(
            processes: [],
            sessions: [ctx.makeSession(outputOffset: -60)]
        )

        #expect(followup.recognizedAgentsBySessionID[ctx.sessionID] == .claude)
        #expect(followup.currentRecognizedAgentSessionIDs.isEmpty)
        #expect(followup.agentSessionIDsByWorktreeID[ctx.worktreeID] == Set([ctx.sessionID]))
        #expect(followup.activeAgentLeafIDs.isEmpty)
    }

    @Test("resolve prefers the highest-activity agent process when a pane contains multiple agents")
    func resolvePrefersHighestActivityAgentPerLeaf() {
        let state = ctx.resolve(
            processes: [
                ctx.makeProcess(
                    executable: "claude", agent: .claude, cpu: 1
                ),
                ctx.makeProcess(
                    executable: "codex", agent: .codex, cpu: 8
                ),
            ],
            sessions: [ctx.makeSession()]
        )

        #expect(state.activeAgentByLeafID[ctx.leafID] == .codex)
        #expect(state.recognizedAgentsBySessionID[ctx.sessionID] == .codex)
    }

    @Test("resolve does not mark a recognized but idle agent process as actively running")
    func resolveLeavesIdleRecognizedAgentOutOfActiveSets() {
        let state = ctx.resolve(
            processes: [
                ctx.makeProcess(
                    executable: "codex", agent: .codex, cpu: 0.1
                ),
            ],
            sessions: [ctx.makeSession(outputOffset: -60)]
        )

        #expect(state.recognizedAgentsBySessionID[ctx.sessionID] == .codex)
        #expect(state.currentRecognizedAgentSessionIDs == Set([ctx.sessionID]))
        #expect(state.activeAgentLeafIDs.isEmpty)
        #expect(state.activeAgentWorktreeIDs.isEmpty)
        #expect(state.activeAgentByLeafID.isEmpty)
    }

    @Test("resolve does not revive agent running state from non-agent CPU after the agent exits")
    func resolveDoesNotTreatPostExitShellCPUAsAgentActivity() {
        ctx.recognizedAgents = [ctx.sessionID: .claude]

        let state = ctx.resolve(
            processes: [
                ctx.makeProcess(
                    executable: "python3", agent: nil, cpu: 6.5
                ),
            ],
            sessions: [ctx.makeSession(outputOffset: -30)]
        )

        expectInactive(state)
        #expect(state.recognizedAgentsBySessionID[ctx.sessionID] == .claude)
    }

    @Test(
        "resolve does not revive agent running state from shell output after the agent process exits"
    )
    func resolveDoesNotTreatPostExitShellOutputAsAgentActivity() {
        _ = ctx.resolve(
            processes: [
                ctx.makeProcess(
                    executable: "claude", agent: .claude, cpu: 10
                ),
            ],
            sessions: [ctx.makeSession()]
        )

        let followup = ctx.resolve(
            processes: [],
            sessions: [ctx.makeSession(outputOffset: -1)]
        )

        #expect(followup.recognizedAgentsBySessionID[ctx.sessionID] == .claude)
        expectInactive(followup)
    }
}
