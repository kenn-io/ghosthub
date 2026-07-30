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
        let view = BorrowedTmuxSessionView(
            handle: BorrowedTmuxSessionHandle(
                id: UUID(), hostID: UUID(), name: "editor", surfaceID: UUID()
            ),
            hostName: "build-box",
            connectionState: .disconnected(reason: "SSH handshake failed"),
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: { retryCount += 1 }
        )
        #expect(view.disconnectionReason == "SSH handshake failed")
        view.onRetryRequest()
        #expect(retryCount == 1)
    }

    @Test("an exited tmux client is presented as a closed session")
    func endedSessionPresentation() {
        let view = BorrowedTmuxSessionView(
            handle: BorrowedTmuxSessionHandle(
                id: UUID(), hostID: UUID(), name: "editor", surfaceID: UUID()
            ),
            hostName: "build-box",
            connectionState: .disconnected(
                reason: "The tmux client exited."
            ),
            sessionClosed: true,
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {}
        )

        #expect(view.disconnectionTitle == "Session ended")
        #expect(view.recoveryActionTitle == "Reopen")
    }

    @Test("a closed attachment does not claim the session ended")
    func closedAttachmentPresentation() {
        let view = BorrowedTmuxSessionView(
            handle: BorrowedTmuxSessionHandle(
                id: UUID(), hostID: UUID(), name: "editor", surfaceID: UUID()
            ),
            hostName: "build-box",
            connectionState: .disconnected(
                reason: "The tmux attachment closed."
            ),
            attachmentClosed: true,
            surface: { nil },
            onCloseRequest: {},
            onRetryRequest: {}
        )

        #expect(view.disconnectionTitle == "Attachment closed")
        #expect(view.recoveryActionTitle == "Reconnect")
    }
}
