import Foundation
import GhosthubSettings
import Testing
@testable import GhosthubUI

@Suite("Workspace SSH host-key review")
@MainActor
struct SSHHostKeyReviewModelTests {
    @Test("approval retries inventory for the same host")
    func approvalRetriesInventoryForSameHost() async {
        let hostID = UUID()
        let confirmation = SSHHostKeyConfirmation(
            destination: "operator@build-node.example.test",
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
            return .success(confirmation)
        }

        #expect(reviewedHostID == hostID)
        #expect(model.confirmation == confirmation)

        var trustedHostID: UUID?
        var trustedConfirmation: SSHHostKeyConfirmation?
        var didRetryInventory = false
        await model.trust(
            using: { requestedHostID, requestedConfirmation in
                trustedHostID = requestedHostID
                trustedConfirmation = requestedConfirmation
                return .success(())
            },
            onTrusted: { didRetryInventory = true }
        )

        #expect(trustedHostID == hostID)
        #expect(trustedConfirmation == confirmation)
        #expect(didRetryInventory)
        #expect(!model.isPresented)
    }
}
