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

    @Test("remote warnings open connection recovery directly")
    func remoteWarningsOpenConnectionRecovery() {
        let hostID = UUID()
        let host = HostSummary(
            id: hostID,
            configKey: "build-node",
            name: "Build Node",
            kind: .remote,
            platform: .linux,
            sshDestination: "operator@build.example.test"
        )

        #expect(InventoryWarningDestination(
            message: "Remote inventory unavailable",
            host: host
        ) == .connectionRecovery(
            hostID,
            "Remote inventory unavailable"
        ))
    }

    @Test("local warnings retain inventory details")
    func localWarningsRetainDetails() {
        let host = HostSummary(
            id: UUID(),
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            preferredTransport: .local
        )
        let warning = PresentedInventoryWarning(
            message: "Local inventory unavailable",
            isHostScoped: true
        )

        #expect(InventoryWarningDestination(
            message: warning.message,
            host: host
        ) == .details(warning))
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
