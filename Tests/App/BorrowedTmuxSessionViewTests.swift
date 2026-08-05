import AppKit
import GhosthubTmux
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubApp

@MainActor
struct BorrowedTmuxSessionViewTests {
    @Test("a failed borrowed attachment shows its reason and retries")
    func failureShowsReasonAndRetry() {
        var retryCount = 0
        var settingsCount = 0
        let view = BorrowedTmuxSessionView(
            handle: BorrowedTmuxSessionHandle(
                id: UUID(), hostID: UUID(), name: "editor", surfaceID: UUID()
            ),
            hostName: "build-box",
            isRemoteHost: true,
            connectionState: .disconnected(reason: "SSH handshake failed"),
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: { retryCount += 1 },
            onHostSettingsRequest: { settingsCount += 1 }
        )
        #expect(view.disconnectionReason == "SSH handshake failed")
        #expect(view.showsHostSettingsAction)
        view.onRetryRequest()
        view.onHostSettingsRequest()
        #expect(retryCount == 1)
        #expect(settingsCount == 1)
    }

    @Test("an exited tmux client is presented as a closed session")
    func endedSessionPresentation() {
        let view = BorrowedTmuxSessionView(
            handle: BorrowedTmuxSessionHandle(
                id: UUID(), hostID: UUID(), name: "editor", surfaceID: UUID()
            ),
            hostName: "build-box",
            isRemoteHost: true,
            connectionState: .disconnected(
                reason: "The tmux client exited."
            ),
            sessionClosed: true,
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {},
            onHostSettingsRequest: {}
        )

        #expect(view.disconnectionTitle == "Session ended")
        #expect(view.recoveryActionTitle == "Reopen")
        #expect(!view.showsHostSettingsAction)
    }

    @Test("a closed attachment does not claim the session ended")
    func closedAttachmentPresentation() {
        let view = BorrowedTmuxSessionView(
            handle: BorrowedTmuxSessionHandle(
                id: UUID(), hostID: UUID(), name: "editor", surfaceID: UUID()
            ),
            hostName: "build-box",
            isRemoteHost: true,
            connectionState: .disconnected(
                reason: "The tmux attachment closed."
            ),
            attachmentClosure: .detached,
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {},
            onHostSettingsRequest: {}
        )

        #expect(view.disconnectionTitle == "Attachment closed")
        #expect(view.recoveryActionTitle == "Reconnect")
        #expect(!view.showsHostSettingsAction)
    }

    @Test("a failed remote attachment offers host settings")
    func remoteAttachmentFailureShowsHostSettings() {
        let view = BorrowedTmuxSessionView(
            handle: BorrowedTmuxSessionHandle(
                id: UUID(), hostID: UUID(), name: "editor", surfaceID: UUID()
            ),
            hostName: "build-box",
            isRemoteHost: true,
            connectionState: .disconnected(reason: "SSH connection failed"),
            attachmentClosure: .processExited,
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {},
            onHostSettingsRequest: {}
        )

        #expect(view.disconnectionTitle == "Unable to attach")
        #expect(view.recoveryActionTitle == "Retry")
        #expect(view.showsHostSettingsAction)
    }

    @Test("local attachment failures do not offer remote host settings")
    func localFailureDoesNotShowHostSettings() {
        let view = BorrowedTmuxSessionView(
            handle: BorrowedTmuxSessionHandle(
                id: UUID(), hostID: UUID(), name: "editor", surfaceID: UUID()
            ),
            hostName: "This Mac",
            isRemoteHost: false,
            connectionState: .disconnected(reason: "tmux unavailable"),
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {},
            onHostSettingsRequest: {}
        )

        #expect(!view.showsHostSettingsAction)
    }
}
