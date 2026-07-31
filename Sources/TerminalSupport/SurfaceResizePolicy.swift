package enum SurfaceResizeDecision: Equatable {
    case immediate
    case deferredUntilLiveResizeEnds
}

package enum SurfaceResizePolicy {
    package static func decision(
        isLiveResize: Bool
    ) -> SurfaceResizeDecision {
        isLiveResize ? .deferredUntilLiveResizeEnds : .immediate
    }
}
