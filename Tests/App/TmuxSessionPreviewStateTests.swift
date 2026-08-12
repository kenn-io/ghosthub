import Foundation
import GhosthubSettings
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("Tmux session preview state")
struct TmuxSessionPreviewStateTests {
    private let originalIdentity = TmuxSessionIdentity(
        serverPID: "101",
        sessionID: "$1",
        createdAt: "1000"
    )
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("new state awaits its first frame")
    func emptyState() {
        let state = TmuxSessionPreviewState<String>()

        #expect(state.visibleFrame == nil)
        #expect(state.quarantinedFrame == nil)
        #expect(state.placeholder == .awaitingFirstFrame)
    }

    @Test("captures replace frames but unchanged seeds preserve metadata")
    func captureAndUnchangedSeed() {
        var state = TmuxSessionPreviewState<String>()

        let didCapture = state.recordCapture(
            image: "first",
            capturedAt: capturedAt,
            ioSurfaceSeed: 7,
            identity: originalIdentity
        )
        #expect(didCapture)
        #expect(state.visibleFrame?.image == "first")
        #expect(state.placeholder == nil)

        let didCaptureDuplicate = state.recordCapture(
            image: "duplicate",
            capturedAt: capturedAt.addingTimeInterval(5),
            ioSurfaceSeed: 7,
            identity: originalIdentity
        )
        #expect(!didCaptureDuplicate)
        #expect(state.visibleFrame?.image == "first")
        #expect(state.visibleFrame?.capturedAt == capturedAt)
    }

    @Test("failed captures preserve a valid frame")
    func captureFailurePreservesFrame() {
        var state = stateWithFrame()

        state.recordCaptureFailure()

        #expect(state.visibleFrame?.image == "frame")
        #expect(state.visibleFrame?.ioSurfaceSeed == 7)
    }

    @Test("reconnect quarantines pixels until the same identity verifies")
    func reconnectIdentityFence() {
        var state = stateWithFrame()

        state.beginReconnect()
        #expect(state.visibleFrame == nil)
        #expect(state.quarantinedFrame?.image == "frame")
        #expect(state.placeholder == .reconnecting)

        state.verifyIdentity(originalIdentity)
        #expect(state.visibleFrame?.image == "frame")
        #expect(state.quarantinedFrame == nil)
        #expect(state.placeholder == nil)
    }

    @Test(arguments: [
        nil,
        TmuxSessionIdentity(
            serverPID: "202",
            sessionID: "$2",
            createdAt: "2000"
        ),
    ] as [TmuxSessionIdentity?])
    func missingOrChangedIdentityDeletesQuarantinedPixels(
        identity: TmuxSessionIdentity?
    ) {
        var state = stateWithFrame()
        state.beginReconnect()

        state.verifyIdentity(identity)

        #expect(state.visibleFrame == nil)
        #expect(state.quarantinedFrame == nil)
    }

    @Test("live limit state is visible until a slot becomes available")
    func liveLimitState() {
        var state = TmuxSessionPreviewState<String>()

        state.setLiveLimitReached(true)
        #expect(state.placeholder == .liveLimitReached)

        state.setLiveLimitReached(false)
        #expect(state.placeholder == .awaitingFirstFrame)
    }

    @Test("turning previews off clears all captured metadata")
    func offClearsState() {
        var state = stateWithFrame()
        state.beginReconnect()

        state.setMode(.off)

        #expect(state.visibleFrame == nil)
        #expect(state.quarantinedFrame == nil)
        #expect(state.placeholder == .awaitingFirstFrame)
    }

    private func stateWithFrame() -> TmuxSessionPreviewState<String> {
        var state = TmuxSessionPreviewState<String>()
        _ = state.recordCapture(
            image: "frame",
            capturedAt: capturedAt,
            ioSurfaceSeed: 7,
            identity: originalIdentity
        )
        return state
    }
}
