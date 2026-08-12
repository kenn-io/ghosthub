import Foundation
import GhosthubSettings
import GhosthubTerminal
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
            captureToken: captureToken(surfaceID: 1, seed: 7),
            identity: originalIdentity
        )
        #expect(didCapture)
        #expect(state.visibleFrame?.image == "first")
        #expect(state.placeholder == nil)

        let didCaptureDuplicate = state.recordCapture(
            image: "duplicate",
            capturedAt: capturedAt.addingTimeInterval(5),
            captureToken: captureToken(surfaceID: 1, seed: 7),
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
        #expect(state.visibleFrame?.captureToken.seed == 7)
    }

    @Test("a replacement IOSurface with the same seed is a new frame")
    func replacementSurfaceWithRepeatedSeed() {
        var state = stateWithFrame()

        let didCapture = state.recordCapture(
            image: "replacement",
            capturedAt: capturedAt.addingTimeInterval(5),
            captureToken: captureToken(surfaceID: 2, seed: 7),
            identity: originalIdentity
        )

        #expect(didCapture)
        #expect(state.visibleFrame?.image == "replacement")
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

    @Test("verifying an unchanged visible identity preserves its frame")
    func visibleIdentityVerificationPreservesFrame() {
        var state = stateWithFrame()

        state.verifyIdentity(originalIdentity)

        #expect(state.visibleFrame?.image == "frame")
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

    @Test("budget release cannot reveal disconnected pixels")
    func budgetReleaseDuringDisconnection() {
        var state = stateWithFrame()
        state.setLiveLimitReached(true)
        state.setDisconnected()

        state.setLiveLimitReached(false)

        #expect(state.visibleFrame == nil)
        #expect(state.quarantinedFrame?.image == "frame")
        #expect(state.placeholder == .disconnected)
    }

    @Test("budget release preserves reconnect quarantine")
    func budgetReleaseDuringReconnect() {
        var state = stateWithFrame()
        state.setLiveLimitReached(true)
        state.beginReconnect()

        state.setLiveLimitReached(false)

        #expect(state.visibleFrame == nil)
        #expect(state.quarantinedFrame?.image == "frame")
        #expect(state.placeholder == .reconnecting)
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
            captureToken: captureToken(surfaceID: 1, seed: 7),
            identity: originalIdentity
        )
        return state
    }

    private func captureToken(
        surfaceID: UInt32,
        seed: UInt32
    ) -> TerminalSurfaceCaptureToken {
        TerminalSurfaceCaptureToken(surfaceID: surfaceID, seed: seed)
    }
}
