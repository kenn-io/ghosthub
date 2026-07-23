import Testing
@testable import GhosthubTerminalSupport

@MainActor
struct LibghosttySurfaceRuntimeCallbacksTests {
    @Test("surface runtime callbacks invoke configured closures")
    func surfaceRuntimeCallbacksInvokeConfiguredClosures() {
        let spy = RuntimeCallbacksSpy()
        let callbacks = spy.callbacks

        callbacks.readClipboard?(.selection, nil)
        callbacks.closeSurface?(true)

        #expect(spy.recordedClipboardLocation == .selection)
        #expect(spy.recordedCloseProcessAlive == true)
    }
}
