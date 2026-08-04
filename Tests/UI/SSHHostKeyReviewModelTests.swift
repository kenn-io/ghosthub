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

    @Test("sequential approvals authenticate only after the final host")
    func sequentialApprovalsAuthenticateAfterFinalHost() async {
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

        await model.review(
            hostID: hostID,
            hostName: "Build Node"
        ) {
            .hostKey(proxyConfirmation)
        }

        #expect(model.hostID == hostID)
        #expect(model.confirmation == proxyConfirmation)
        #expect(model.presentation == .hostKey)

        var trustedHostID: UUID?
        var trustedConfirmation: SSHHostKeyConfirmation?
        var didBeginAuthentication = false
        await model.trust(
            using: { requestedHostID, requestedConfirmation in
                trustedHostID = requestedHostID
                trustedConfirmation = requestedConfirmation
                return .success(targetConfirmation)
            },
            onTrusted: { didBeginAuthentication = true }
        )

        #expect(trustedHostID == hostID)
        #expect(trustedConfirmation == proxyConfirmation)
        #expect(model.confirmation == targetConfirmation)
        #expect(!didBeginAuthentication)
        #expect(model.isPresented)

        await model.trust(
            using: { _, _ in .success(nil) },
            onTrusted: { didBeginAuthentication = true }
        )

        #expect(didBeginAuthentication)
        #expect(model.isPresented)
        #expect(model.presentation == .authentication)
    }

    @Test("an SSH authentication failure opens the in-app terminal")
    func authenticationFailureOpensTerminal() async {
        let model = WorkspaceSSHHostKeyReviewModel()

        await model.review(hostID: UUID(), hostName: "Build Node") {
            .authenticationRequired
        }

        #expect(model.presentation == .authentication)
        #expect(model.errorMessage == nil)
        #expect(model.confirmation == nil)
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
            await model.review(hostID: hostID, hostName: "Old") {
                await gate.wait()
                return .hostKey(staleConfirmation)
            }
        }

        while !model.isLoading {
            await Task.yield()
        }
        #expect(model.presentation == .checking)
        model.dismiss()
        await model.review(hostID: hostID, hostName: "Current") {
            .hostKey(currentConfirmation)
        }
        await gate.release()
        await staleRequest.value

        #expect(model.hostName == "Current")
        #expect(model.confirmation == currentConfirmation)
        #expect(model.errorMessage == nil)
    }

    @Test("a failed probe becomes connection recovery")
    func failedProbeBecomesConnectionRecovery() async {
        let model = WorkspaceSSHHostKeyReviewModel()

        await model.review(hostID: UUID(), hostName: "Build Node") {
            .connectionIssue("Authentication failed.")
        }

        #expect(model.presentation == .connectionIssue)
        #expect(model.errorMessage == "Authentication failed.")
        #expect(model.confirmation == nil)
    }

    @Test("a reachable host preserves its inventory diagnostic")
    func reachableHostPreservesInventoryDiagnostic() async {
        let model = WorkspaceSSHHostKeyReviewModel()

        await model.review(hostID: UUID(), hostName: "Build Node") {
            .inventoryIssue("tmux is not available on this host.")
        }

        #expect(model.presentation == .inventoryIssue)
        #expect(model.errorMessage == "tmux is not available on this host.")
        #expect(model.confirmation == nil)
    }
}
