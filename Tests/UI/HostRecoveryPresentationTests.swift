import Foundation
import GhosthubSettings
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

struct HostRecoveryPresentationTests {
    @Test("sequential host-key confirmations have distinct sheet identities")
    func sequentialConfirmationsHaveDistinctIdentities() {
        let draft = SSHHostDraft(
            configKey: "build-node",
            name: "Build Node",
            platform: .linux,
            sshDestination: "operator@build.example.test"
        )
        let target = HostOperationTarget(draft)
        let first = PendingSSHHostTrust(
            target: target,
            confirmation: confirmation(
                destination: "jump.example.test",
                fingerprint: "SHA256:jump-synthetic-fingerprint"
            )
        )
        let second = PendingSSHHostTrust(
            target: target,
            confirmation: confirmation(
                destination: "build.example.test",
                fingerprint: "SHA256:build-synthetic-fingerprint"
            )
        )

        #expect(first.id != second.id)
    }

    @Test("local warnings retain settings without offering SSH trust")
    func localWarningActions() {
        let warning = PresentedInventoryWarning(
            message: "Local inventory unavailable",
            isHostScoped: true,
            reviewHostID: nil
        )

        #expect(warning.isHostScoped)
        #expect(warning.reviewHostID == nil)
    }

    private func confirmation(
        destination: String,
        fingerprint: String
    ) -> SSHHostKeyConfirmation {
        SSHHostKeyConfirmation(
            destination: destination,
            connectionDestination: "operator@build.example.test",
            algorithm: "ED25519",
            fingerprint: fingerprint,
            openSSHPrompt: "synthetic OpenSSH prompt"
        )
    }
}
