import Foundation
import GhosthubSettings
import Testing
@testable import GhosthubUI

@Suite("Workspace SSH host-key review")
@MainActor
struct SSHHostKeyReviewModelTests {
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
}
