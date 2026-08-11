import Foundation
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("Borrowed Zellij presentation")
@MainActor
struct BorrowedZellijSessionViewTests {
    @Test("automatic transport recovery offers immediate reconnect")
    func reconnectingPresentation() {
        let view = makeView(
            recoveryState: .reconnecting(message: "Waiting for build-box.")
        )

        #expect(view.recoveryTitle == "Connection interrupted")
        #expect(view.showsReconnectProgress)
        #expect(view.primaryRecoveryActionTitle == "Reconnect Now")
        #expect(!view.showsReviewConnection)
        #expect(view.showsHostSettingsAction)
    }

    @Test("authentication recovery offers connection review")
    func attentionPresentation() {
        let view = makeView(
            recoveryState: .needsAttention(
                message: "SSH authentication is required.",
                canReviewConnection: true
            )
        )

        #expect(view.recoveryTitle == "Connection needs attention")
        #expect(!view.showsReconnectProgress)
        #expect(view.showsReviewConnection)
        #expect(view.showsHostSettingsAction)
    }

    private func makeView(
        recoveryState: NativeSessionRecoveryState
    ) -> BorrowedZellijSessionView {
        BorrowedZellijSessionView(
            handle: BorrowedZellijSessionHandle(
                id: UUID(),
                hostID: UUID(),
                name: "api",
                surfaceID: UUID()
            ),
            hostName: "build-box",
            isRemoteHost: true,
            connectionState: .reconnecting(reason: "Recovering."),
            recoveryState: recoveryState,
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {},
            onReconnectNow: {},
            onReviewConnection: {},
            onHostSettingsRequest: {}
        )
    }
}
