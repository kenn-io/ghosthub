import Foundation
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("Borrowed Herdr presentation")
@MainActor
struct BorrowedHerdrSessionViewTests {
    @Test("manual detach offers reconnect without host repair")
    func detachedPresentation() {
        let view = makeView(
            connectionState: .disconnected(
                reason: "The Herdr attachment closed."
            ),
            attachmentClosure: .detached
        )

        #expect(view.disconnectionTitle == "Attachment closed")
        #expect(view.recoveryActionTitle == "Reconnect")
        #expect(!view.showsHostSettingsAction)
    }

    @Test("non-transport failure offers retry and remote settings")
    func failedPresentation() {
        let view = makeView(
            connectionState: .disconnected(reason: "Herdr client exited."),
            attachmentClosure: .processExited(code: 9)
        )

        #expect(view.disconnectionTitle == "Unable to attach")
        #expect(view.recoveryActionTitle == "Retry")
        #expect(view.showsHostSettingsAction)
        #expect(!view.disconnectionTitle.localizedCaseInsensitiveContains(
            "session ended"
        ))
    }

    @Test("automatic transport recovery offers immediate reconnect")
    func reconnectingPresentation() {
        let view = makeView(
            connectionState: .disconnected(reason: nil),
            recoveryState: .reconnecting(
                message: "Waiting for build-box."
            )
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
            connectionState: .disconnected(reason: nil),
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

    @Test("local failures do not offer remote settings")
    func localFailure() {
        let view = BorrowedHerdrSessionView(
            handle: BorrowedHerdrSessionHandle(
                id: UUID(),
                hostID: UUID(),
                name: "api",
                surfaceID: UUID()
            ),
            hostName: "This Mac",
            isRemoteHost: false,
            connectionState: .disconnected(reason: "Herdr unavailable"),
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {},
            onHostSettingsRequest: {}
        )

        #expect(!view.showsHostSettingsAction)
    }

    private func makeView(
        connectionState: ConnectionState?,
        recoveryState: NativeSessionRecoveryState? = nil,
        attachmentClosure: BorrowedHerdrAttachmentClosure? = nil
    ) -> BorrowedHerdrSessionView {
        BorrowedHerdrSessionView(
            handle: BorrowedHerdrSessionHandle(
                id: UUID(),
                hostID: UUID(),
                name: "api",
                surfaceID: UUID()
            ),
            hostName: "build-box",
            isRemoteHost: true,
            connectionState: connectionState,
            recoveryState: recoveryState,
            attachmentClosure: attachmentClosure,
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {},
            onReconnectNow: {},
            onReviewConnection: {},
            onHostSettingsRequest: {}
        )
    }
}
