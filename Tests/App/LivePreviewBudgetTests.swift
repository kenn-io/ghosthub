import Foundation
import Testing
@testable import GhosthubApp

@Suite("Live preview budget")
@MainActor
struct LivePreviewBudgetTests {
    private let sceneA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let sceneB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let hostID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    @Test("the first four inactive requests receive slots in FIFO order")
    func grantsAndPromotesInRequestOrder() {
        let budget = LivePreviewBudget(limit: 4)
        let requests = (0 ..< 6).map { request(sceneID: sceneA, index: $0) }

        for id in requests {
            budget.request(id)
        }

        #expect(budget.granted == Set(requests.prefix(4)))
        #expect(budget.isWaiting(requests[4]))
        #expect(budget.isWaiting(requests[5]))

        budget.release(requests[1])

        #expect(budget.isGranted(requests[4]))
        #expect(budget.isWaiting(requests[5]))
    }

    @Test("duplicate requests are idempotent")
    func duplicateRequestsAreIdempotent() {
        let budget = LivePreviewBudget(limit: 1)
        let first = request(sceneID: sceneA, index: 0)
        let second = request(sceneID: sceneB, index: 1)

        budget.request(first)
        budget.request(first)
        budget.request(second)
        budget.release(first)

        #expect(budget.isGranted(second))
        #expect(!budget.isWaiting(first))
    }

    @Test("releasing a scene promotes requests from other scenes")
    func releaseScene() {
        let budget = LivePreviewBudget(limit: 2)
        let a1 = request(sceneID: sceneA, index: 0)
        let a2 = request(sceneID: sceneA, index: 1)
        let b1 = request(sceneID: sceneB, index: 2)
        budget.request(a1)
        budget.request(a2)
        budget.request(b1)

        budget.release(sceneID: sceneA)

        #expect(budget.granted == [b1])
        #expect(!budget.isWaiting(a1))
        #expect(!budget.isWaiting(a2))
    }

    @Test("active previews do not request inactive slots")
    func activePreviewDoesNotConsumeSlot() {
        let budget = LivePreviewBudget(limit: 1)
        let active = request(sceneID: sceneA, index: 0)
        let inactive = request(sceneID: sceneB, index: 1)

        budget.setInactive(false, for: active)
        budget.setInactive(true, for: inactive)

        #expect(!budget.isGranted(active))
        #expect(!budget.isWaiting(active))
        #expect(budget.isGranted(inactive))
    }

    private func request(
        sceneID: UUID,
        index: Int
    ) -> LivePreviewRequestID {
        LivePreviewRequestID(
            sceneID: sceneID,
            presentation: TmuxPreviewKey(
                hostID: hostID,
                name: "session-\(index)",
                socketName: index.isMultiple(of: 2) ? nil : "custom"
            )
        )
    }
}
