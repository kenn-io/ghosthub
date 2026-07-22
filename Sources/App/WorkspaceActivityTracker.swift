import Foundation
import GhosthubWorkspace

enum WorkspaceActivityTiming {
    static let recentOutputWindow: TimeInterval = 5
}

struct WorkspaceAgentSessionState: Equatable, Sendable {
    var recognizedAgentsBySessionID: [UUID: WorkspaceKnownAgent]
    var currentRecognizedAgentSessionIDs: Set<UUID>
    var agentSessionIDsByWorktreeID: [UUID: Set<UUID>]
    var activeAgentWorktreeIDs: Set<UUID>
    var activeAgentLeafIDs: Set<UUID>
    var activeAgentByLeafID: [UUID: WorkspaceKnownAgent]

    static let empty = WorkspaceAgentSessionState(
        recognizedAgentsBySessionID: [:],
        currentRecognizedAgentSessionIDs: [],
        agentSessionIDsByWorktreeID: [:],
        activeAgentWorktreeIDs: [],
        activeAgentLeafIDs: [],
        activeAgentByLeafID: [:]
    )
}

enum AgentSessionResolver {
    static func resolve(
        processes: [WorkspaceProcessResource],
        aliveSessions: [TerminalSessionSummary],
        leafSessionIDsByWorktreeID: [UUID: [UUID: UUID]],
        existingRecognizedAgentsBySessionID: [UUID: WorkspaceKnownAgent],
        now: Date,
        recentOutputWindow: TimeInterval = WorkspaceActivityTiming
            .recentOutputWindow,
        activeCPUThreshold: Double = 0.5
    ) -> WorkspaceAgentSessionState {
        let recognizedAgentsByLeafID = recognizedAgentsByLeafID(
            processes: processes
        )
        let cpuActiveAgentsByLeafID = activeAgentsByLeafID(
            processes: processes,
            activeCPUThreshold: activeCPUThreshold
        )
        let cpuActiveLeafIDs: Set<UUID> = Set(
            processes.compactMap { process in
                guard process.sample.cpuPercent > activeCPUThreshold else {
                    return nil
                }
                return process.leafID
            }
        )

        let aliveSessionIDs = Set(aliveSessions.map(\.id))
        var recognizedAgentsBySessionID = existingRecognizedAgentsBySessionID
            .filter { aliveSessionIDs.contains($0.key) }
        var currentRecognizedAgentSessionIDs: Set<UUID> = []
        var agentSessionIDsByWorktreeID: [UUID: Set<UUID>] = [:]

        for session in aliveSessions {
            if recognizedAgentsBySessionID[session.id] != nil,
               let worktreeID = session.worktreeID {
                agentSessionIDsByWorktreeID[worktreeID, default: []]
                    .insert(session.id)
            }
        }

        let leafMappings = leafSessionIDsByWorktreeID.flatMap {
            worktreeID, sessionIDsByLeafID in
            sessionIDsByLeafID.map { leafID, sessionID in
                (leafID, (worktreeID, sessionID))
            }
        }
        let worktreeAndSessionByLeafID = Dictionary(
            uniqueKeysWithValues: leafMappings
        )
        let leafIDBySessionID = Dictionary(
            uniqueKeysWithValues: leafMappings.map { leafID, mapping in
                (mapping.1, leafID)
            }
        )
        let sessionByID = Dictionary(
            uniqueKeysWithValues: aliveSessions.map { ($0.id, $0) }
        )

        for (leafID, agent) in recognizedAgentsByLeafID {
            guard let (worktreeID, sessionID) =
                worktreeAndSessionByLeafID[leafID],
                aliveSessionIDs.contains(sessionID)
            else {
                continue
            }
            recognizedAgentsBySessionID[sessionID] = agent
            currentRecognizedAgentSessionIDs.insert(sessionID)
            agentSessionIDsByWorktreeID[worktreeID, default: []]
                .insert(sessionID)
        }

        var activeAgentByLeafID = cpuActiveAgentsByLeafID
        var activeAgentWorktreeIDs: Set<UUID> = []

        for session in aliveSessions {
            guard let agent = recognizedAgentsBySessionID[session.id],
                  let worktreeID = session.worktreeID
            else {
                continue
            }

            let hasRecentOutput: Bool
            if let lastOutputAt = session.lastOutputAt {
                hasRecentOutput = now.timeIntervalSince(lastOutputAt)
                    <= recentOutputWindow
            } else {
                hasRecentOutput = false
            }

            let isCPUActive = leafIDBySessionID[session.id]
                .map { cpuActiveAgentsByLeafID[$0] != nil } ?? false
            let isLeafCPUActive = leafIDBySessionID[session.id]
                .map { cpuActiveLeafIDs.contains($0) } ?? false
            let hasCurrentRecognizedAgent = leafIDBySessionID[session.id]
                .map { recognizedAgentsByLeafID[$0] != nil } ?? false

            guard isCPUActive
                || (isLeafCPUActive && hasCurrentRecognizedAgent)
                || (hasRecentOutput && hasCurrentRecognizedAgent)
            else {
                continue
            }

            activeAgentWorktreeIDs.insert(worktreeID)
            if let leafID = leafIDBySessionID[session.id] {
                activeAgentByLeafID[leafID] =
                    activeAgentByLeafID[leafID] ?? agent
            }
        }

        for (leafID, agent) in cpuActiveAgentsByLeafID {
            guard let (worktreeID, sessionID) =
                worktreeAndSessionByLeafID[leafID],
                sessionByID[sessionID] != nil,
                recognizedAgentsBySessionID[sessionID] != nil
            else {
                continue
            }
            activeAgentByLeafID[leafID] = agent
            activeAgentWorktreeIDs.insert(worktreeID)
        }

        let activeAgentLeafIDs = Set(activeAgentByLeafID.keys)

        return WorkspaceAgentSessionState(
            recognizedAgentsBySessionID: recognizedAgentsBySessionID,
            currentRecognizedAgentSessionIDs:
            currentRecognizedAgentSessionIDs,
            agentSessionIDsByWorktreeID: agentSessionIDsByWorktreeID,
            activeAgentWorktreeIDs: activeAgentWorktreeIDs,
            activeAgentLeafIDs: activeAgentLeafIDs,
            activeAgentByLeafID: activeAgentByLeafID
        )
    }

    private static func recognizedAgentsByLeafID(
        processes: [WorkspaceProcessResource]
    ) -> [UUID: WorkspaceKnownAgent] {
        bestAgentsByLeafID(
            from: processes.filter { $0.recognizedAgent != nil }
        )
    }

    private static func activeAgentsByLeafID(
        processes: [WorkspaceProcessResource],
        activeCPUThreshold: Double
    ) -> [UUID: WorkspaceKnownAgent] {
        bestAgentsByLeafID(
            from: processes.filter {
                $0.recognizedAgent != nil
                    && $0.sample.cpuPercent > activeCPUThreshold
            }
        )
    }

    private static func bestAgentsByLeafID(
        from processes: [WorkspaceProcessResource]
    ) -> [UUID: WorkspaceKnownAgent] {
        var bestAgentsByLeafID:
            [UUID: (agent: WorkspaceKnownAgent, score: Double)] = [:]
        for process in processes {
            guard let leafID = process.leafID,
                  let agent = process.recognizedAgent
            else {
                continue
            }

            let score = process.sample.cpuPercent * 1_000
                + Double(process.sample.residentMB)
            let existing = bestAgentsByLeafID[leafID]

            if existing == nil || score > existing?.score ?? .zero {
                bestAgentsByLeafID[leafID] = (agent, score)
            }
        }

        return bestAgentsByLeafID.mapValues(\.agent)
    }
}

enum AttentionNotificationKind: Equatable, Sendable {
    case worktreeBecameIdle
    case agentsNeedAttention
}

struct IdleNotificationRequest: Equatable, Sendable {
    let worktreeID: UUID
    let kind: AttentionNotificationKind
}

struct WorkspaceActivityEvaluation: Equatable, Sendable {
    var paneAgentActivities: [UUID: PaneAgentActivity]
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
    var leafSessionIDsByWorktreeID: [UUID: [UUID: UUID]]
    var activeAgentLeafIDs: Set<UUID>
    var activeProcessLeafIDs: Set<UUID>
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
            paneAgentActivities: buildPaneAgentActivities(
                snapshot: input.snapshot,
                selectedWorktreeID: input.selectedWorktreeID,
                now: now,
                defaultIdleThresholdSeconds:
                input.defaultIdleThresholdSeconds,
                workspaceConfiguration: input.workspaceConfiguration,
                sessionHintsByID: input.sessionHintsByID,
                recognizedAgentBySessionID:
                input.recognizedAgentBySessionID,
                currentRecognizedAgentSessionIDs:
                input.currentRecognizedAgentSessionIDs,
                leafSessionIDsByWorktreeID:
                input.leafSessionIDsByWorktreeID,
                activeAgentLeafIDs: input.activeAgentLeafIDs,
                activeProcessLeafIDs: input.activeProcessLeafIDs
            ),
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

    static func buildPaneAgentActivities(
        snapshot: WorkspaceSnapshot,
        selectedWorktreeID: UUID?,
        now: Date,
        defaultIdleThresholdSeconds: Int,
        workspaceConfiguration: WorkspaceConfiguration,
        sessionHintsByID: [UUID: WorkspaceActivitySessionHint],
        recognizedAgentBySessionID: [UUID: WorkspaceKnownAgent],
        currentRecognizedAgentSessionIDs: Set<UUID>,
        leafSessionIDsByWorktreeID: [UUID: [UUID: UUID]],
        activeAgentLeafIDs: Set<UUID>,
        activeProcessLeafIDs: Set<UUID>
    ) -> [UUID: PaneAgentActivity] {
        let sessionsByID = Dictionary(
            uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) }
        )
        var result: [UUID: PaneAgentActivity] = [:]

        for (worktreeID, sessionIDsByLeafID) in leafSessionIDsByWorktreeID {
            guard let worktree = snapshot.worktree(id: worktreeID) else {
                continue
            }

            for (leafID, sessionID) in sessionIDsByLeafID {
                guard let agent = recognizedAgentBySessionID[sessionID],
                      let session = sessionsByID[sessionID]
                else {
                    continue
                }

                let isCurrentRecognizedAgentSession =
                    currentRecognizedAgentSessionIDs.contains(sessionID)
                let state: PaneAgentActivityState
                if activeAgentLeafIDs.contains(leafID)
                    || (activeProcessLeafIDs.contains(leafID)
                        && isCurrentRecognizedAgentSession) {
                    state = .running
                } else if isSessionNeedingAttention(
                    session,
                    worktree: worktree,
                    selectedWorktreeID: selectedWorktreeID,
                    now: now,
                    defaultIdleThresholdSeconds:
                    defaultIdleThresholdSeconds,
                    workspaceConfiguration: workspaceConfiguration,
                    sessionHintsByID: sessionHintsByID,
                    recognizedAgentBySessionID:
                    recognizedAgentBySessionID
                ) {
                    state = .needsAttention
                } else if session.isAlive {
                    state = .active
                } else {
                    state = .idle
                }

                result[leafID] = PaneAgentActivity(
                    agent: agent,
                    activityState: state
                )
            }
        }

        return result
    }

    static func isSessionNeedingAttention(
        _ session: TerminalSessionSummary,
        worktree: WorktreeSummary,
        selectedWorktreeID: UUID?,
        now: Date,
        defaultIdleThresholdSeconds: Int,
        workspaceConfiguration: WorkspaceConfiguration,
        sessionHintsByID: [UUID: WorkspaceActivitySessionHint],
        recognizedAgentBySessionID: [UUID: WorkspaceKnownAgent]
    ) -> Bool {
        if selectedWorktreeID == worktree.id {
            return false
        }

        if let lastViewedAt = worktree.lastViewedAt,
           let lastOutputAt = session.lastOutputAt,
           lastOutputAt > lastViewedAt {
            return true
        }

        guard session.isAlive,
              let lastOutputAt = session.lastOutputAt
        else {
            return false
        }

        let threshold = idleThresholdSeconds(
            for: session,
            defaultIdleThresholdSeconds: defaultIdleThresholdSeconds,
            workspaceConfiguration: workspaceConfiguration,
            sessionHintsByID: sessionHintsByID,
            recognizedAgentBySessionID: recognizedAgentBySessionID
        )
        guard threshold > 0 else {
            return false
        }

        return now.timeIntervalSince(lastOutputAt) > TimeInterval(threshold)
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

    static func recognizedAgentHint(
        for hint: WorkspaceActivitySessionHint
    ) -> WorkspaceKnownAgent? {
        if let presetID = hint.presetID,
           let agent = WorkspaceKnownAgent.recognize(
               executableName: presetID
           ) {
            return agent
        }
        return WorkspaceKnownAgent.recognize(
            executableName: hint.command
        )
    }
}
