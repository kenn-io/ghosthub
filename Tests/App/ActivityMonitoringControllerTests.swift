import AppKit
import XCTest
import GhosthubPersistence
import GhosthubWorkspace
@testable import GhosthubApp

@MainActor
final class ActivityMonitoringControllerTests: XCTestCase {
    func testControlModeProcessRootNeverFallsBackToSilentSurfaceChild() {
        XCTAssertEqual(
            ActivityMonitoringController.processRootPID(
                controlModeRoot: .local(4_242),
                surfaceChildPID: 99
            ),
            4_242
        )
        XCTAssertNil(
            ActivityMonitoringController.processRootPID(
                controlModeRoot: .unavailable,
                surfaceChildPID: 99
            )
        )
        XCTAssertEqual(
            ActivityMonitoringController.processRootPID(
                controlModeRoot: nil,
                surfaceChildPID: 99
            ),
            99
        )
    }

    func testOutputFlushIntervalStaysInsideRecentOutputWindow() {
        XCTAssertLessThan(
            ActivityMonitoringController
                .outputFlushIntervalSeconds,
            WorkspaceActivityTiming.recentOutputWindow
        )
    }

    func testRefreshActivityStatePostsIdleNotificationOnceAndUpdatesDockBadge() throws {
        let env = try setupStandardEnvironment()
        let staleOutput = Date(
            timeIntervalSinceReferenceDate: 800_000_000
        ).addingTimeInterval(-120)
        let now = Date(
            timeIntervalSinceReferenceDate: 800_000_000
        )
        let sessionID = UUID()
        let session = TerminalSessionRecord.fixture(
            id: sessionID,
            hostID: env.host.id,
            worktreeID: env.worktree.id,
            scopedKey: "surface:\(env.host.id.uuidString):\(env.worktree.id.uuidString):worktreeShell:root",
            kind: .shell, launchMode: .loginShell,
            backend: .localPTY,
            workingDirectory: env.worktree.path,
            childPID: 999,
            restartPolicy: .never,
            lastOutputAt: staleOutput,
            createdAt: staleOutput, updatedAt: staleOutput
        )
        let notificationService = NotificationServiceStub()
        try env.database.terminalSessions.upsert(session)

        // Include the session summary in the snapshot so the activity
        // tracker can find it. In production this comes from the daemon
        // snapshot assembled by SnapshotAssembler.
        let sessionSummary = TerminalSessionSummary(
            id: sessionID,
            hostID: env.host.id,
            worktreeID: env.worktree.id,
            childPID: 999,
            isAlive: true,
            lastOutputAt: staleOutput
        )
        let snapshotWithSessions = WorkspaceSnapshot(
            hosts: env.snapshot.hosts,
            projects: env.snapshot.projects,
            worktrees: env.snapshot.worktrees,
            sessions: [sessionSummary]
        )

        let model = try makeModel(
            database: env.database,
            localHostID: env.host.id,
            snapshot: snapshotWithSessions,
            notificationService: notificationService
        )

        model.activityController.refreshActivityState(now: now)
        model.activityController.refreshActivityState(
            now: now.addingTimeInterval(5)
        )

        XCTAssertEqual(
            notificationService.idleNotifications,
            [
                NotificationServiceStub.IdleNotification(
                    worktreeName: env.worktree.branch,
                    projectName: env.project.name
                ),
            ]
        )
        XCTAssertEqual(
            notificationService.dockBadgeCounts,
            [1, 1]
        )
    }

    func testRefreshActivityStateDoesNotPostIdleNotificationForRecentUnseenOutput() throws {
        let env = try setupStandardEnvironment()
        let lastViewedAt = Date(
            timeIntervalSinceReferenceDate: 800_000_000
        )
        let recentOutput = lastViewedAt.addingTimeInterval(1)
        let notificationService = NotificationServiceStub()
        let session = TerminalSessionRecord.fixture(
            hostID: env.host.id,
            worktreeID: env.worktree.id,
            scopedKey: "surface:\(env.host.id.uuidString):\(env.worktree.id.uuidString):worktreeShell:root",
            kind: .shell, launchMode: .loginShell,
            backend: .localPTY,
            workingDirectory: env.worktree.path,
            childPID: 999,
            restartPolicy: .never,
            lastOutputAt: recentOutput,
            createdAt: recentOutput, updatedAt: recentOutput
        )

        // Inject a snapshot where the worktree has lastViewedAt set.
        let viewedWorktree = WorktreeSummary(
            id: env.worktree.id,
            hostID: env.host.id,
            projectID: env.project.id,
            scopedKey: env.worktree.scopedKey,
            name: env.worktree.name,
            path: env.worktree.path,
            branch: env.worktree.branch,
            isPrimary: env.worktree.isPrimary,
            lastViewedAt: lastViewedAt
        )
        let viewedSnapshot = WorkspaceSnapshot(
            hosts: env.snapshot.hosts,
            projects: env.snapshot.projects,
            worktrees: [viewedWorktree]
        )

        try env.database.terminalSessions.upsert(session)

        let model = try makeModel(
            database: env.database,
            localHostID: env.host.id,
            snapshot: viewedSnapshot,
            notificationService: notificationService
        )

        model.activityController.refreshActivityState(
            now: recentOutput.addingTimeInterval(1)
        )

        XCTAssertTrue(
            notificationService.idleNotifications.isEmpty
        )
        XCTAssertTrue(
            notificationService.agentAttentionNotifications
                .isEmpty
        )
        XCTAssertEqual(
            notificationService.dockBadgeCounts,
            [0]
        )
    }

    func testUnchangedActivityRefreshDoesNotPublish() throws {
        let env = try setupStandardEnvironment()
        let model = try makeModel(
            database: env.database,
            localHostID: env.host.id,
            snapshot: env.snapshot
        )
        let now = Date(
            timeIntervalSinceReferenceDate: 800_000_000
        )

        model.activityController.refreshActivityState(now: now)
        var updateCount = 0
        let updates = model.activityController.objectWillChange.sink {
            updateCount += 1
        }

        model.activityController.refreshActivityState(
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(updateCount, 0)
        withExtendedLifetime(updates) {}
    }

}
