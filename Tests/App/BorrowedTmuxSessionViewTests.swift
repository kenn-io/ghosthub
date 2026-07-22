import AppKit
import GhosthubTmux
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubApp

@MainActor
struct BorrowedTmuxSessionViewTests {
    @Test("a failed borrowed attachment shows its reason and retries")
    func failureShowsReasonAndRetry() throws {
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
}
