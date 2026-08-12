import Combine
import Foundation

struct TmuxPreviewKey: Hashable, Sendable {
    let hostID: UUID
    let name: String
    let socketName: String?
}

struct LivePreviewRequestID: Hashable, Sendable {
    let sceneID: UUID
    let presentation: TmuxPreviewKey
}

@MainActor
final class LivePreviewBudget: ObservableObject {
    static let shared = LivePreviewBudget(limit: 4)

    @Published private(set) var granted: Set<LivePreviewRequestID> = []

    private let limit: Int
    private var requests: [LivePreviewRequestID] = []

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func request(_ id: LivePreviewRequestID) {
        guard !requests.contains(id) else { return }
        requests.append(id)
        recomputeGrants()
    }

    func release(_ id: LivePreviewRequestID) {
        requests.removeAll { $0 == id }
        recomputeGrants()
    }

    func release(sceneID: UUID) {
        requests.removeAll { $0.sceneID == sceneID }
        recomputeGrants()
    }

    func setInactive(
        _ isInactive: Bool,
        for id: LivePreviewRequestID
    ) {
        if isInactive {
            request(id)
        } else {
            release(id)
        }
    }

    func isGranted(_ id: LivePreviewRequestID) -> Bool {
        granted.contains(id)
    }

    func isWaiting(_ id: LivePreviewRequestID) -> Bool {
        requests.contains(id) && !granted.contains(id)
    }

    private func recomputeGrants() {
        granted = Set(requests.prefix(limit))
    }
}
