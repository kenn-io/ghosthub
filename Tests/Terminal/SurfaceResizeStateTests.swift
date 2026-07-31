import Testing
@testable import GhosthubTerminal

struct SurfaceResizeStateTests {
    var state = SurfaceResizeState()

    @Test("applying a backing-scale resize clears stale deferred state")
    mutating func applyClearsPendingDeferredResize() {
        state.setPending(width: 800, height: 600)
        state.apply(width: 1600, height: 1200)

        expectState(
            pending: nil,
            last: .init(width: 1600, height: 1200)
        )
    }

    @Test("pending resize is consumed once")
    mutating func pendingResizeIsConsumedOnce() {
        state.setPending(width: 1024, height: 768)

        #expect(state.consumePending() == .init(width: 1024, height: 768))
        #expect(state.consumePending() == nil)
    }

    // MARK: - Helpers

    private func expectState(
        pending: SurfaceResizeState.Size? = nil,
        last: SurfaceResizeState.Size? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            state.pendingPixelSize == pending,
            sourceLocation: sourceLocation
        )
        #expect(
            state.lastPixelSize == last,
            sourceLocation: sourceLocation
        )
    }
}
