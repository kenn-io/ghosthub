import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

struct WorktreeRowStatusTests {
    // MARK: - Fixture helpers

    private func makeWorktree(
        branch: String = "feature",
        diffAdded: Int? = nil,
        diffRemoved: Int? = nil,
        syncAhead: Int? = nil,
        syncBehind: Int? = nil,
        linkedPR: Int? = nil,
        prTitle: String? = nil,
        prState: PRState? = nil,
        checks: ChecksStatus? = nil
    ) -> WorktreeSummary {
        WorktreeSummary.fixture(
            branch: branch,
            diffAdded: diffAdded,
            diffRemoved: diffRemoved,
            syncAhead: syncAhead,
            syncBehind: syncBehind,
            linkedPullRequestNumber: linkedPR,
            pullRequestTitle: prTitle,
            pullRequestState: prState,
            checksStatus: checks
        )
    }

    private func aliveAgentSession(_ worktreeID: UUID) -> TerminalSessionSummary {
        TerminalSessionSummary(
            id: UUID(),
            hostID: UUID(),
            worktreeID: worktreeID,
            runtimeKind: .agent,
            isAlive: true
        )
    }

    private func aliveShellSession(_ worktreeID: UUID) -> TerminalSessionSummary {
        TerminalSessionSummary(
            id: UUID(),
            hostID: UUID(),
            worktreeID: worktreeID,
            runtimeKind: .plainShell,
            isAlive: true
        )
    }

    private func deadSession(_ worktreeID: UUID) -> TerminalSessionSummary {
        TerminalSessionSummary(
            id: UUID(),
            hostID: UUID(),
            worktreeID: worktreeID,
            runtimeKind: .agent,
            isAlive: false
        )
    }

    // MARK: - Tests

    @Test func dirtyAheadRunningAgentTwoLine() {
        let w = makeWorktree(
            diffAdded: 24,
            diffRemoved: 3,
            syncAhead: 2,
            linkedPR: 142,
            prTitle: "Fix PR refresh flow",
            prState: .open,
            checks: .success
        )
        let s = WorktreeRowStatus.make(for: w, sessions: [aliveAgentSession(w.id)])
        #expect(s.showsSecondLine)
        #expect(s.isRunning && s.isAgentRunning)
        #expect(s.syncAhead == 2 && s.syncBehind == nil)
        #expect(s.checks == .success)
    }

    @Test func cleanNoPRSingleLine() {
        let w = makeWorktree(branch: "main")
        let s = WorktreeRowStatus.make(for: w, sessions: [])
        #expect(!s.showsSecondLine && !s.isRunning && s.diffAdded == nil)
    }

    @Test func draftPendingChecks() {
        let w = makeWorktree(
            linkedPR: 99,
            prTitle: "WIP: draft feature",
            prState: .draft,
            checks: .pending
        )
        let s = WorktreeRowStatus.make(for: w, sessions: [])
        #expect(s.isDraft)
        #expect(s.checks == .pending)
        #expect(s.showsSecondLine)
    }

    @Test func zeroDiffsMappedToNil() {
        let w = makeWorktree(diffAdded: 0, diffRemoved: 0)
        let s = WorktreeRowStatus.make(for: w, sessions: [])
        #expect(s.diffAdded == nil)
        #expect(s.diffRemoved == nil)
    }

    @Test func syncBehindOnly() {
        let w = makeWorktree(syncBehind: 5)
        let s = WorktreeRowStatus.make(for: w, sessions: [])
        #expect(s.syncBehind == 5)
        #expect(s.syncAhead == nil)
    }

    @Test func deadSessionNotRunning() {
        let w = makeWorktree()
        let s = WorktreeRowStatus.make(for: w, sessions: [deadSession(w.id)])
        #expect(!s.isRunning)
        #expect(!s.isAgentRunning)
    }

    @Test func aliveShellNotAgent() {
        let w = makeWorktree()
        let s = WorktreeRowStatus.make(for: w, sessions: [aliveShellSession(w.id)])
        #expect(s.isRunning)
        #expect(!s.isAgentRunning)
    }

    @Test func checksFailure() {
        let w = makeWorktree(linkedPR: 7, checks: .failure)
        let s = WorktreeRowStatus.make(for: w, sessions: [])
        #expect(s.checks == .failure)
    }

    @Test func checksNoneMapsToNil() {
        let w = makeWorktree(checks: ChecksStatus.none)
        let s = WorktreeRowStatus.make(for: w, sessions: [])
        #expect(s.checks == nil)
    }

    @Test func prFieldsPopulated() {
        let w = makeWorktree(linkedPR: 42, prTitle: "Some PR", prState: .open)
        let s = WorktreeRowStatus.make(for: w, sessions: [])
        #expect(s.prNumber == 42)
        #expect(s.prTitle == "Some PR")
        #expect(!s.isDraft)
        #expect(s.showsSecondLine)
    }

    @Test func syncZeroMapsToNil() {
        let w = makeWorktree(syncAhead: 0, syncBehind: 0)
        let s = WorktreeRowStatus.make(for: w, sessions: [])
        #expect(s.syncAhead == nil)
        #expect(s.syncBehind == nil)
    }
}
