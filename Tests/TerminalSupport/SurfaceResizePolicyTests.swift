import Testing
@testable import GhosthubTerminalSupport

struct SurfaceResizePolicyTests {
    @Test("live window resizing waits for the drag to end")
    func liveResizeDefers() {
        #expect(
            SurfaceResizePolicy.decision(isLiveResize: true)
                == .deferredUntilLiveResizeEnds
        )
    }

    @Test("non-live layout changes resize immediately")
    func nonLiveResizeIsImmediate() {
        #expect(
            SurfaceResizePolicy.decision(isLiveResize: false) == .immediate
        )
    }
}
