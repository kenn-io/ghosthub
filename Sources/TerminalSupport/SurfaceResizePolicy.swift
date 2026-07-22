import Foundation

package enum SurfaceResizeDecision: Equatable {
    case immediate
    case deferred(delay: TimeInterval)
}

package enum SurfaceResizePolicy {
    /// After a resize event arrives, wait this long for more
    /// events before applying. Each new event resets the timer,
    /// so during continuous dragging the terminal never
    /// re-layouts — it only updates once events stop arriving.
    package static let settleDelay: TimeInterval = 0.08

    /// After this much idle time since the last apply, treat
    /// the next event as the start of a new gesture and apply
    /// immediately (gives instant feedback on first interaction).
    package static let idleThreshold: TimeInterval = 0.5

    package static func decision(
        now: TimeInterval,
        lastAppliedAt: TimeInterval?,
        lastEventAt: TimeInterval?
    ) -> SurfaceResizeDecision {
        guard let lastAppliedAt else {
            return .immediate
        }

        let sinceLastApply = now - lastAppliedAt
        let sinceLastEvent = lastEventAt.map { now - $0 }
            ?? sinceLastApply

        // First event after idle: apply immediately
        if sinceLastEvent >= idleThreshold {
            return .immediate
        }

        // During rapid events: always defer
        return .deferred(delay: settleDelay)
    }
}
