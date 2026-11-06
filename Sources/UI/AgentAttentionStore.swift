import Combine
import Foundation
import GhosthubWorkspace

/// Remembers which finished agent turns the user has already seen, so the
/// attention dot clears once a session has been viewed and stays cleared
/// across launches. Pending approvals and questions are never acknowledged;
/// they show until the agent moves on.
@MainActor
public final class AgentAttentionStore: ObservableObject {
    public static let shared = AgentAttentionStore()
    static let preferenceKey = "agentAttentionAcknowledgementsV1"
    /// Bounds stored acknowledgements; the oldest stamps are dropped first.
    static let capacity = 512

    @Published public private(set) var acknowledgedDoneStamps: [String: Int]
    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        acknowledgedDoneStamps = (userDefaults.dictionary(forKey: Self.preferenceKey)
            as? [String: Int]) ?? [:]
    }

    /// Attention for every discovered tmux session that needs it, keyed by
    /// `endpointKey(hostID:name:socketName:)`.
    public func attentionByEndpoint(
        in snapshot: WorkspaceSnapshot
    ) -> [String: AgentAttention] {
        snapshot.hosts.reduce(into: [:]) { result, host in
            for session in host.tmuxSessions where !session.agentPanes.isEmpty {
                guard let attention = session.agentAttention(
                    acknowledgedDoneStamp: acknowledgedDoneStamps[
                        session.agentAttentionKey(hostID: host.id)
                    ]
                ) else { continue }
                result[Self.endpointKey(
                    hostID: host.id,
                    name: session.name,
                    socketName: session.socketName
                )] = attention
            }
        }
    }

    /// Whether the session reports a finished turn the user has not seen.
    public func hasUnacknowledgedDone(_ session: TmuxSessionSummary, hostID: UUID) -> Bool {
        guard let stamp = session.latestAgentDoneStamp else { return false }
        return (acknowledgedDoneStamps[session.agentAttentionKey(hostID: hostID)] ?? 0) < stamp
    }

    /// Records that the user has seen every finished turn currently
    /// reported for the session.
    public func acknowledge(_ session: TmuxSessionSummary, hostID: UUID) {
        guard hasUnacknowledgedDone(session, hostID: hostID),
              let stamp = session.latestAgentDoneStamp
        else { return }
        let key = session.agentAttentionKey(hostID: hostID)
        var updated = acknowledgedDoneStamps
        updated[key] = stamp
        if updated.count > Self.capacity {
            for (oldKey, _) in updated.sorted(by: { $0.value < $1.value })
                .prefix(updated.count - Self.capacity) {
                updated[oldKey] = nil
            }
        }
        acknowledgedDoneStamps = updated
        defaults.set(updated, forKey: Self.preferenceKey)
    }

    public nonisolated static func endpointKey(
        hostID: UUID,
        name: String,
        socketName: String?
    ) -> String {
        [hostID.uuidString, socketName ?? "default", name].joined(separator: "|")
    }
}
