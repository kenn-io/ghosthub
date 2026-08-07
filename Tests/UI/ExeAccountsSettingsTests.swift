import Foundation
import GhosthubSettings
import Testing
@testable import GhosthubUI

@Suite("exe.dev account connection")
struct ExeAccountsSettingsTests {
    @Test("interactive requirements enter SSH authentication")
    func interactiveRequirementsEnterAuthentication() {
        let action = ExeAccountTrustAction.resolve(
            .success(.authenticationRequired)
        )

        guard case .authenticate = action else {
            Issue.record("Expected the account to enter SSH authentication")
            return
        }
    }

    @Test("trusted destinations probe final account authentication")
    func trustedDestinationProbesAccount() {
        let action = ExeAccountTrustAction.resolve(.success(.none))

        guard case .probe = action else {
            Issue.record("Expected final account connection probing")
            return
        }
    }

    @Test("inventory authentication failures enter secure entry")
    func inventoryAuthenticationRequiresAuthentication() {
        let action = ExeAccountConnectionAction.resolve(
            .authenticationRequired
        )

        guard case .authenticate = action else {
            Issue.record("Expected the account to enter SSH authentication")
            return
        }
    }

    @Test("authentication targets match normalized account drafts")
    func authenticationTargetsMatchNormalizedDrafts() throws {
        let sanitized = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )
        let target = PendingExeAuthentication(account: sanitized)

        let account = try #require(target.currentAccount(in: [
            ExeAccount(
                configKey: " personal ",
                name: " Personal ",
                sshDestination: " exe.dev "
            ),
        ]))

        #expect(account == sanitized)
    }

    @Test("connection operations reject changed account drafts")
    func connectionOperationsRejectChangedDrafts() {
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )
        let operation = ExeAccountConnectionOperation(
            accounts: [account],
            id: UUID()
        )

        #expect(operation.matches(operation, accounts: [account]))
        #expect(!operation.matches(operation, accounts: [ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "other.exe.dev"
        )]))
        #expect(!operation.matches(nil, accounts: [account]))
    }

    @MainActor
    @Test("account failures do not block remaining connections")
    func accountFailuresDoNotBlockRemainingConnections() async {
        let trustFailure = ExeAccount(
            configKey: "trust-failure",
            name: "Trust failure",
            sshDestination: "trust.exe.dev"
        )
        let probeFailure = ExeAccount(
            configKey: "probe-failure",
            name: "Probe failure",
            sshDestination: "probe.exe.dev"
        )
        var probedAccounts: [String] = []
        let runner = ExeAccountConnectionRunner(
            pendingTrust: { account in
                if account == trustFailure {
                    return .failure(.message("Trust failed"))
                }
                return .success(.none)
            },
            probe: { account in
                probedAccounts.append(account.id)
                return .failed("Probe failed")
            }
        )
        let operation = ExeAccountConnectionOperation(
            accounts: [trustFailure, probeFailure]
        )

        let result = await runner.run(operation, isCurrent: { true })
        guard case let .refresh(accounts, messages) = result else {
            Issue.record("Expected eligible accounts to refresh")
            return
        }

        #expect(accounts == [trustFailure, probeFailure])
        #expect(messages[trustFailure.id] == "Trust failed")
        #expect(messages[probeFailure.id] == "Probe failed")
        #expect(probedAccounts == [probeFailure.id])
    }
}
