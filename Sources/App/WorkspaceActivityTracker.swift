import Foundation
import GhosthubWorkspace

enum AttentionNotificationKind: Equatable, Sendable {
    case worktreeBecameIdle
    case agentsNeedAttention
}

struct IdleNotificationRequest: Equatable, Sendable {
    let worktreeID: UUID
    let kind: AttentionNotificationKind
}

struct WorkspaceActivityEvaluation: Equatable, Sendable {
    var unseenCount: Int
    var notificationsToPost: [IdleNotificationRequest]
    var nextNotifiedWorktreeIDs: Set<UUID>
}

struct ActivityEvaluationInput: Sendable {
    var snapshot: WorkspaceSnapshot
    var selectedWorktreeID: UUID?
    var suppressSelectedWorktreeNotifications: Bool
    var notifiedIdleWorktreeIDs: Set<UUID>
    var defaultIdleThresholdSeconds: Int
    var workspaceConfiguration: WorkspaceConfiguration
    var sessionHintsByID: [UUID: WorkspaceActivitySessionHint]
    var recognizedAgentBySessionID: [UUID: WorkspaceKnownAgent]
    var currentRecognizedAgentSessionIDs: Set<UUID>
}

enum WorkspaceActivityTracker {
    static func evaluate(
        now: Date,
        input: ActivityEvaluationInput
    ) -> WorkspaceActivityEvaluation {
        let attentionKinds = idleAttentionNotificationKinds(
            snapshot: input.snapshot,
            now: now,
            defaultIdleThresholdSeconds: input.defaultIdleThresholdSeconds,
            workspaceConfiguration: input.workspaceConfiguration,
            sessionHintsByID: input.sessionHintsByID,
            recognizedAgentBySessionID: input.recognizedAgentBySessionID,
            currentRecognizedAgentSessionIDs:
            input.currentRecognizedAgentSessionIDs
        )
        let activeAttentionWorktreeIDs = Set(attentionKinds.keys)
        var nextNotifiedWorktreeIDs = input.notifiedIdleWorktreeIDs
            .intersection(activeAttentionWorktreeIDs)
        var notificationsToPost: [IdleNotificationRequest] = []

        for worktree in input.snapshot.worktrees {
            guard let kind = attentionKinds[worktree.id] else {
                continue
            }
            guard !nextNotifiedWorktreeIDs.contains(worktree.id) else {
                continue
            }
            if input.suppressSelectedWorktreeNotifications,
               worktree.id == input.selectedWorktreeID {
                continue
            }
            notificationsToPost.append(
                IdleNotificationRequest(
                    worktreeID: worktree.id,
                    kind: kind
                )
            )
            nextNotifiedWorktreeIDs.insert(worktree.id)
        }

        return WorkspaceActivityEvaluation(
            unseenCount: attentionKinds.count,
            notificationsToPost: notificationsToPost,
            nextNotifiedWorktreeIDs: nextNotifiedWorktreeIDs
        )
    }

    static func idleAttentionNotificationKinds(
        snapshot: WorkspaceSnapshot,
        now: Date,
        defaultIdleThresholdSeconds: Int,
        workspaceConfiguration: WorkspaceConfiguration,
        sessionHintsByID: [UUID: WorkspaceActivitySessionHint],
        recognizedAgentBySessionID: [UUID: WorkspaceKnownAgent],
        currentRecognizedAgentSessionIDs: Set<UUID>
    ) -> [UUID: AttentionNotificationKind] {
        snapshot.worktrees.reduce(into: [:]) { result, worktree in
            let sessions = snapshot.sessions(for: worktree.id)
            if let kind = idleAttentionNotificationKind(
                sessions: sessions,
                now: now,
                idleThresholdsBySessionID: idleThresholdsBySessionID(
                    sessions: sessions,
                    defaultIdleThresholdSeconds:
                    defaultIdleThresholdSeconds,
                    workspaceConfiguration: workspaceConfiguration,
                    sessionHintsByID: sessionHintsByID,
                    recognizedAgentBySessionID:
                    recognizedAgentBySessionID
                ),
                defaultIdleThresholdSeconds: defaultIdleThresholdSeconds,
                currentRecognizedAgentSessionIDs:
                currentRecognizedAgentSessionIDs
            ) {
                result[worktree.id] = kind
            }
        }
    }

    static func idleAttentionNotificationKind(
        sessions: [TerminalSessionSummary],
        now: Date,
        idleThresholdsBySessionID: [UUID: Int],
        defaultIdleThresholdSeconds: Int,
        currentRecognizedAgentSessionIDs: Set<UUID>
    ) -> AttentionNotificationKind? {
        let triggeringSessions = sessions.filter { session in
            guard session.isAlive,
                  let lastOutputAt = session.lastOutputAt
            else {
                return false
            }
            let threshold = idleThresholdsBySessionID[session.id]
                ?? defaultIdleThresholdSeconds
            guard threshold > 0 else {
                return false
            }
            return now.timeIntervalSince(lastOutputAt)
                > TimeInterval(threshold)
        }

        guard !triggeringSessions.isEmpty else {
            return nil
        }

        if triggeringSessions.contains(where: {
            currentRecognizedAgentSessionIDs.contains($0.id)
        }) {
            return .agentsNeedAttention
        }

        return .worktreeBecameIdle
    }

    static func idleThresholdSeconds(
        for session: TerminalSessionSummary,
        defaultIdleThresholdSeconds: Int,
        workspaceConfiguration: WorkspaceConfiguration,
        sessionHintsByID: [UUID: WorkspaceActivitySessionHint],
        recognizedAgentBySessionID: [UUID: WorkspaceKnownAgent]
    ) -> Int {
        guard let hint = sessionHintsByID[session.id] else {
            return configuredIdleThreshold(
                defaultValue: defaultIdleThresholdSeconds,
                workspaceConfiguration: workspaceConfiguration,
                recognizedAgent: recognizedAgentBySessionID[session.id]
            )
        }
        if let presetID = hint.presetID {
            if let override = workspaceConfiguration.notifications
                .presetOverrides[presetID] {
                return override.idleThresholdSeconds
            }
            if let presetThreshold = workspaceConfiguration
                .preset(id: presetID)?
                .idleThresholdSeconds {
                return presetThreshold
            }
        }
        return configuredIdleThreshold(
            defaultValue: defaultIdleThresholdSeconds,
            workspaceConfiguration: workspaceConfiguration,
            recognizedAgent: recognizedAgentBySessionID[session.id]
        )
    }

    static func idleThresholdsBySessionID(
        sessions: [TerminalSessionSummary],
        defaultIdleThresholdSeconds: Int,
        workspaceConfiguration: WorkspaceConfiguration,
        sessionHintsByID: [UUID: WorkspaceActivitySessionHint],
        recognizedAgentBySessionID: [UUID: WorkspaceKnownAgent]
    ) -> [UUID: Int] {
        Dictionary(
            uniqueKeysWithValues: sessions.map { session in
                (
                    session.id,
                    idleThresholdSeconds(
                        for: session,
                        defaultIdleThresholdSeconds:
                        defaultIdleThresholdSeconds,
                        workspaceConfiguration: workspaceConfiguration,
                        sessionHintsByID: sessionHintsByID,
                        recognizedAgentBySessionID:
                        recognizedAgentBySessionID
                    )
                )
            }
        )
    }

    static func configuredIdleThreshold(
        defaultValue: Int = 30,
        workspaceConfiguration: WorkspaceConfiguration,
        recognizedAgent: WorkspaceKnownAgent?
    ) -> Int {
        guard let recognizedAgent else {
            return defaultValue
        }

        if let override = workspaceConfiguration.notifications
            .presetOverrides[recognizedAgent.rawValue] {
            return override.idleThresholdSeconds
        }
        if let threshold = workspaceConfiguration
            .preset(id: recognizedAgent.rawValue)?
            .idleThresholdSeconds {
            return threshold
        }
        return defaultValue
    }

}
