import Foundation
import GhosthubSettings
import Testing
@testable import GhosthubUI

@Suite("Workspace SSH host-key review")
@MainActor
struct SSHHostKeyReviewModelTests {
    private actor ReviewGate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("sequential approvals retry inventory only after the final host")
    func sequentialApprovalsRetryInventoryAfterFinalHost() async {
        let hostID = UUID()
        let proxyConfirmation = SSHHostKeyConfirmation(
            destination: "jump.example.test",
            connectionDestination: "operator@build-node.example.test",
            algorithm: "ED25519",
            fingerprint: "SHA256:proxy-synthetic-fingerprint",
            openSSHPrompt: "synthetic proxy OpenSSH prompt"
        )
        let targetConfirmation = SSHHostKeyConfirmation(
            destination: "build-node.example.test",
            connectionDestination: "operator@build-node.example.test",
            algorithm: "ED25519",
            fingerprint: "SHA256:synthetic-fingerprint",
            openSSHPrompt: "synthetic OpenSSH prompt"
        )
        let model = WorkspaceSSHHostKeyReviewModel()
        var reviewedHostID: UUID?

        await model.review(
            hostID: hostID,
            hostName: "Build Node"
        ) { requestedHostID in
            reviewedHostID = requestedHostID
            return .success(proxyConfirmation)
        }

        #expect(reviewedHostID == hostID)
        #expect(model.confirmation == proxyConfirmation)
        #expect(model.presentation == .hostKey)

        var trustedHostID: UUID?
        var trustedConfirmation: SSHHostKeyConfirmation?
        var didRetryInventory = false
        await model.trust(
            using: { requestedHostID, requestedConfirmation in
                trustedHostID = requestedHostID
                trustedConfirmation = requestedConfirmation
                return .success(targetConfirmation)
            },
            onTrusted: { didRetryInventory = true }
        )

        #expect(trustedHostID == hostID)
        #expect(trustedConfirmation == proxyConfirmation)
        #expect(model.confirmation == targetConfirmation)
        #expect(!didRetryInventory)
        #expect(model.isPresented)

        await model.trust(
            using: { _, _ in .success(nil) },
            onTrusted: { didRetryInventory = true }
        )

        #expect(didRetryInventory)
        #expect(!model.isPresented)
    }

    @Test("an older request cannot overwrite a reopened review")
    func staleRequestCannotOverwriteReopenedReview() async {
        let hostID = UUID()
        let staleConfirmation = SSHHostKeyConfirmation(
            destination: "old.example.test",
            connectionDestination: "operator@old.example.test",
            algorithm: "ED25519",
            fingerprint: "SHA256:old-synthetic-fingerprint",
            openSSHPrompt: "old synthetic OpenSSH prompt"
        )
        let currentConfirmation = SSHHostKeyConfirmation(
            destination: "current.example.test",
            connectionDestination: "operator@current.example.test",
            algorithm: "ED25519",
            fingerprint: "SHA256:current-synthetic-fingerprint",
            openSSHPrompt: "current synthetic OpenSSH prompt"
        )
        let gate = ReviewGate()
        let model = WorkspaceSSHHostKeyReviewModel()
        let staleRequest = Task { @MainActor in
            await model.review(hostID: hostID, hostName: "Old") { _ in
                await gate.wait()
                return .success(staleConfirmation)
            }
        }

        while !model.isLoading {
            await Task.yield()
        }
        #expect(model.presentation == .checking)
        model.dismiss()
        await model.review(hostID: hostID, hostName: "Current") { _ in
            .success(currentConfirmation)
        }
        await gate.release()
        await staleRequest.value

        #expect(model.hostName == "Current")
        #expect(model.confirmation == currentConfirmation)
        #expect(model.errorMessage == nil)
    }

    @Test("a failure without an unseen key becomes connection recovery")
    func noUnseenKeyBecomesConnectionRecovery() async {
        let model = WorkspaceSSHHostKeyReviewModel()

        await model.review(hostID: UUID(), hostName: "Build Node") { _ in
            .success(nil)
        }

        #expect(model.presentation == .connectionIssue)
        #expect(model.confirmation == nil)
    }
}
