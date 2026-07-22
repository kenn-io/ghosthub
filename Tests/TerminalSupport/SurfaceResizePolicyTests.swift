import Foundation
import Testing
@testable import GhosthubTerminalSupport

struct SurfaceResizePolicyTests {
    private static let deferred: SurfaceResizeDecision =
        .deferred(delay: SurfaceResizePolicy.settleDelay)

    private func expectDecision(
        now: TimeInterval,
        lastApplied: TimeInterval?,
        lastEvent: TimeInterval?,
        _ expected: SurfaceResizeDecision,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            SurfaceResizePolicy.decision(
                now: now,
                lastAppliedAt: lastApplied,
                lastEventAt: lastEvent
            ) == expected,
            sourceLocation: sourceLocation
        )
    }

    @Test("first resize applies immediately")
    func firstResizeAppliesImmediately() {
        expectDecision(
            now: 5, lastApplied: nil, lastEvent: nil,
            .immediate
        )
    }

    @Test("rapid consecutive resize defers by the settle delay")
    func rapidResizeDefers() {
        expectDecision(
            now: 10.02, lastApplied: 10, lastEvent: 10.01,
            Self.deferred
        )
    }

    @Test("resize after idle threshold applies immediately")
    func idleResizeAppliesImmediately() {
        expectDecision(
            now: 10 + SurfaceResizePolicy.idleThreshold + 0.01,
            lastApplied: 9, lastEvent: 10,
            .immediate
        )
    }

    @Test("resize during active dragging always defers")
    func activeDraggingDefers() {
        expectDecision(
            now: 10.05, lastApplied: 10, lastEvent: 10.03,
            Self.deferred
        )
    }

    @Test("slower drag cadence still defers while events stay inside the idle threshold")
    func slowerDragCadenceStillDefers() {
        expectDecision(
            now: 10.14, lastApplied: 10, lastEvent: 10.03,
            Self.deferred
        )
    }

    @Test("events only restart immediate resizing after the idle threshold")
    func idleThresholdControlsImmediateRestart() {
        expectDecision(
            now: 10.49, lastApplied: 10, lastEvent: 10.01,
            Self.deferred
        )
        expectDecision(
            now: 10.52, lastApplied: 10, lastEvent: 10.01,
            .immediate
        )
    }
}
