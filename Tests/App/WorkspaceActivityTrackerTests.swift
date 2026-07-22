import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

struct WorkspaceActivityTrackerTests {
    private let fixture = WorkspaceActivityFixture()

    @Test("evaluate posts a new idle notification once and keeps the unseen count")
    func evaluatePostsIdleNotificationOnce() {
        let snapshot = fixture.makeSnapshot(
            lastOutputAt: fixture.now.addingTimeInterval(-60)
        )

        let first = WorkspaceActivityTracker.evaluate(
            now: fixture.now,
            input: makeInput(snapshot: snapshot)
        )
        let second = WorkspaceActivityTracker.evaluate(
            now: fixture.now,
            input: makeInput(
                snapshot: snapshot,
                notifiedIdleWorktreeIDs: first.nextNotifiedWorktreeIDs
            )
        )

        #expect(first.unseenCount == 1)
        #expect(
            first.notificationsToPost == [
                IdleNotificationRequest(
                    worktreeID: fixture.worktreeID,
                    kind: .worktreeBecameIdle
                ),
            ]
        )
        #expect(first.nextNotifiedWorktreeIDs == [fixture.worktreeID])

        #expect(second.unseenCount == 1)
        #expect(second.notificationsToPost.isEmpty)
        #expect(second.nextNotifiedWorktreeIDs == [fixture.worktreeID])
    }

    @Test("evaluate suppresses selected-worktree notifications while preserving unseen count")
    func evaluateSuppressesSelectedWorktreeNotifications() {
        let snapshot = fixture.makeSnapshot(
            lastOutputAt: fixture.now.addingTimeInterval(-60)
        )

        let evaluation = WorkspaceActivityTracker.evaluate(
            now: fixture.now,
            input: makeInput(
                snapshot: snapshot,
                selectedWorktreeID: fixture.worktreeID,
                suppressSelectedWorktreeNotifications: true
            )
        )

        #expect(evaluation.unseenCount == 1)
        #expect(evaluation.notificationsToPost.isEmpty)
        #expect(evaluation.nextNotifiedWorktreeIDs.isEmpty)
    }

    @Test("builds pane agent activities from leaf session state")
    func buildsPaneAgentActivitiesFromLeafSessionState() {
        let leafID = UUID()
        let lastOutputAt = fixture.now.addingTimeInterval(5)
        let snapshot = fixture.makeSnapshot(
            lastOutputAt: lastOutputAt,
            branch: "feature/sidebar",
            lastViewedAt: fixture.now
        )

        let evaluation = WorkspaceActivityTracker.evaluate(
            now: lastOutputAt.addingTimeInterval(1),
            input: makeInput(
                snapshot: snapshot,
                recognizedAgentBySessionID: [fixture.sessionID: .claude],
                leafSessionIDsByWorktreeID: [
                    fixture.worktreeID: [leafID: fixture.sessionID],
                ]
            )
        )

        #expect(
            evaluation.paneAgentActivities[leafID] == PaneAgentActivity(
                agent: .claude,
                activityState: .needsAttention
            )
        )
    }

    @Test("idle attention uses agent-specific route when recognized agent sessions exist")
    func idleAttentionUsesAgentRouteForRecognizedAgentSessions() {
        let sessionID = UUID()

        #expect(
            WorkspaceActivityTracker.idleAttentionNotificationKind(
                sessions: [
                    TerminalSessionSummary(
                        id: sessionID,
                        hostID: UUID(),
                        worktreeID: UUID(),
                        isAlive: true,
                        lastOutputAt: fixture.now
                            .addingTimeInterval(-60)
                    ),
                ],
                now: fixture.now,
                idleThresholdsBySessionID: [
                    sessionID: 15,
                ],
                defaultIdleThresholdSeconds: 30,
                currentRecognizedAgentSessionIDs: [
                    sessionID,
                ]
            ) == .agentsNeedAttention
        )
    }

    @Test("idle attention uses generic route without recognized idle agent sessions")
    func idleAttentionUsesGenericRouteWithoutRecognizedIdleAgents() {
        let idleSessionID = UUID()
        let activeAgentSessionID = UUID()

        #expect(
            WorkspaceActivityTracker.idleAttentionNotificationKind(
                sessions: [
                    TerminalSessionSummary(
                        id: idleSessionID,
                        hostID: UUID(),
                        worktreeID: UUID(),
                        isAlive: true,
                        lastOutputAt: fixture.now
                            .addingTimeInterval(-60)
                    ),
                    TerminalSessionSummary(
                        id: activeAgentSessionID,
                        hostID: UUID(),
                        worktreeID: UUID(),
                        isAlive: true,
                        lastOutputAt: fixture.now
                            .addingTimeInterval(-1)
                    ),
                ],
                now: fixture.now,
                idleThresholdsBySessionID: [
                    idleSessionID: 15,
                    activeAgentSessionID: 15,
                ],
                defaultIdleThresholdSeconds: 30,
                currentRecognizedAgentSessionIDs: [
                    activeAgentSessionID,
                ]
            ) == .worktreeBecameIdle
        )
    }

    @Test("idle attention uses generic route after agent process exits")
    func idleAttentionUsesGenericRouteAfterAgentProcessExits() {
        let sessionID = UUID()

        #expect(
            WorkspaceActivityTracker.idleAttentionNotificationKind(
                sessions: [
                    TerminalSessionSummary(
                        id: sessionID,
                        hostID: UUID(),
                        worktreeID: UUID(),
                        isAlive: true,
                        lastOutputAt: fixture.now
                            .addingTimeInterval(-60)
                    ),
                ],
                now: fixture.now,
                idleThresholdsBySessionID: [
                    sessionID: 15,
                ],
                defaultIdleThresholdSeconds: 30,
                currentRecognizedAgentSessionIDs: []
            ) == .worktreeBecameIdle
        )
    }

    @Test("idle threshold map applies session hints and recognized agents")
    func idleThresholdMapAppliesHintsAndRecognizedAgents() {
        let defaultSessionID = UUID()
        let presetSessionID = UUID()
        let recognizedOnlySessionID = UUID()
        let recognizedSessionID = UUID()
        var configuration = WorkspaceConfiguration.defaults()
        configuration.notifications.presetOverrides = [
            "claude": PresetNotificationConfiguration(
                idleThresholdSeconds: 9
            ),
            "custom": PresetNotificationConfiguration(
                idleThresholdSeconds: 12
            ),
        ]
        configuration.presets.append(
            PresetConfiguration(
                id: "review",
                name: "Review",
                command: "review",
                idleThresholdSeconds: 18
            )
        )

        let thresholds = WorkspaceActivityTracker
            .idleThresholdsBySessionID(
                sessions: [
                    TerminalSessionSummary(
                        id: defaultSessionID,
                        hostID: fixture.hostID,
                        worktreeID: fixture.worktreeID,
                        isAlive: true
                    ),
                    TerminalSessionSummary(
                        id: presetSessionID,
                        hostID: fixture.hostID,
                        worktreeID: fixture.worktreeID,
                        isAlive: true
                    ),
                    TerminalSessionSummary(
                        id: recognizedOnlySessionID,
                        hostID: fixture.hostID,
                        worktreeID: fixture.worktreeID,
                        isAlive: true
                    ),
                    TerminalSessionSummary(
                        id: recognizedSessionID,
                        hostID: fixture.hostID,
                        worktreeID: fixture.worktreeID,
                        isAlive: true
                    ),
                ],
                defaultIdleThresholdSeconds: 30,
                workspaceConfiguration: configuration,
                sessionHintsByID: [
                    presetSessionID: WorkspaceActivitySessionHint(
                        presetID: "review",
                        command: nil
                    ),
                    recognizedSessionID: WorkspaceActivitySessionHint(
                        presetID: "custom",
                        command: nil
                    ),
                ],
                recognizedAgentBySessionID: [
                    recognizedOnlySessionID: .claude,
                    recognizedSessionID: .claude,
                ]
            )

        #expect(thresholds[defaultSessionID] == 30)
        #expect(thresholds[presetSessionID] == 18)
        #expect(thresholds[recognizedOnlySessionID] == 9)
        #expect(thresholds[recognizedSessionID] == 12)
    }
}

private func makeInput(
    snapshot: WorkspaceSnapshot,
    selectedWorktreeID: UUID? = nil,
    suppressSelectedWorktreeNotifications: Bool = false,
    notifiedIdleWorktreeIDs: Set<UUID> = [],
    recognizedAgentBySessionID: [UUID: WorkspaceKnownAgent] = [:],
    leafSessionIDsByWorktreeID: [UUID: [UUID: UUID]] = [:]
) -> ActivityEvaluationInput {
    ActivityEvaluationInput(
        snapshot: snapshot,
        selectedWorktreeID: selectedWorktreeID,
        suppressSelectedWorktreeNotifications: suppressSelectedWorktreeNotifications,
        notifiedIdleWorktreeIDs: notifiedIdleWorktreeIDs,
        defaultIdleThresholdSeconds: 30,
        workspaceConfiguration: .defaults(),
        sessionHintsByID: [:],
        recognizedAgentBySessionID: recognizedAgentBySessionID,
        currentRecognizedAgentSessionIDs: [],
        leafSessionIDsByWorktreeID: leafSessionIDsByWorktreeID,
        activeAgentLeafIDs: [],
        activeProcessLeafIDs: []
    )
}

private struct WorkspaceActivityFixture {
    let hostID = UUID()
    let projectID = UUID()
    let worktreeID = UUID()
    let sessionID = UUID()
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func makeSnapshot(
        lastOutputAt: Date,
        branch: String = "main",
        lastViewedAt: Date? = nil
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            hosts: [
                HostSummary(
                    id: hostID,
                    name: "This Mac",
                    kind: .selfHost,
                    platform: .macOS
                ),
            ],
            projects: [
                ProjectSummary(
                    id: projectID,
                    hostID: hostID,
                    name: "ghosthub",
                    rootPath: "/tmp/ghosthub"
                ),
            ],
            worktrees: [
                WorktreeSummary(
                    id: worktreeID,
                    hostID: hostID,
                    projectID: projectID,
                    name: "ghosthub",
                    path: "/tmp/ghosthub",
                    branch: branch,
                    lastViewedAt: lastViewedAt
                ),
            ],
            sessions: [
                TerminalSessionSummary(
                    id: sessionID,
                    hostID: hostID,
                    worktreeID: worktreeID,
                    isAlive: true,
                    lastOutputAt: lastOutputAt
                ),
            ]
        )
    }
}
