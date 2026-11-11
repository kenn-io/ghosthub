import Foundation
import GhosthubSettings
import GhosthubWorkspace

/// Orders one host's merged session rows for the sidebar.
///
/// Every mode starts from Backend order (backend, then name), so sessions
/// that have no saved manual position land in a predictable place. Stopped
/// Herdr sessions always sink to the bottom.
enum WorkspaceSidebarSessionOrdering {
    static func ordered(
        _ rows: [WorkspaceSidebarRow],
        sort: SidebarSessionSort,
        manualOrder: WorkspaceSidebarOrder,
        agentAttentionByEndpoint: [String: AgentAttention]
    ) -> [WorkspaceSidebarRow] {
        let byBackend = rows.sorted { lhs, rhs in
            let lhsBackend = lhs.sessionBackend ?? .tmux
            let rhsBackend = rhs.sessionBackend ?? .tmux
            if lhsBackend != rhsBackend {
                return lhsBackend < rhsBackend
            }
            return lhs.title.localizedStandardCompare(rhs.title)
                == .orderedAscending
        }
        let sorted: [WorkspaceSidebarRow] = switch sort {
        case .backend:
            byBackend
        case .name:
            stableSorted(byBackend) {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .manual:
            manual(byBackend, order: manualOrder)
        case .attention:
            stableSorted(manual(byBackend, order: manualOrder)) {
                attentionRank($0, agentAttentionByEndpoint)
                    < attentionRank($1, agentAttentionByEndpoint)
            }
        }
        return sorted.filter { $0.herdrSessionState != .stopped }
            + sorted.filter { $0.herdrSessionState == .stopped }
    }

    private static func manual(
        _ rows: [WorkspaceSidebarRow],
        order: WorkspaceSidebarOrder
    ) -> [WorkspaceSidebarRow] {
        order.ordered(rows) { $0.sessionOrderID ?? "" }
    }

    /// Waiting on the user, then working, then done, then everything else.
    private static func attentionRank(
        _ row: WorkspaceSidebarRow,
        _ attentionByEndpoint: [String: AgentAttention]
    ) -> Int {
        guard case let .tmuxSession(hostID, name, socketName) = row.target,
              let attention = attentionByEndpoint[AgentAttentionStore.endpointKey(
                  hostID: hostID,
                  name: name,
                  socketName: socketName
              )]
        else { return 3 }
        switch attention {
        case .approval, .input: return 0
        case .working: return 1
        case .finished: return 2
        }
    }

    private static func stableSorted(
        _ rows: [WorkspaceSidebarRow],
        by areInIncreasingOrder: (WorkspaceSidebarRow, WorkspaceSidebarRow) -> Bool
    ) -> [WorkspaceSidebarRow] {
        rows.enumerated().sorted { lhs, rhs in
            if areInIncreasingOrder(lhs.element, rhs.element) {
                return true
            }
            if areInIncreasingOrder(rhs.element, lhs.element) {
                return false
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }
}
