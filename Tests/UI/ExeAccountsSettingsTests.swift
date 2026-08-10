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
        #expect(!operation.matches(operation, accounts: [ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev",
            tagFilter: "dev"
        )]))
        #expect(!operation.matches(nil, accounts: [account]))
    }

    @Test("discovery counts name the tags they were scoped to")
    @MainActor
    func discoveryCountsNameScopedTags() {
        #expect(ExeAccountsSettingsView.loadedSummary(
            totalVMs: 4,
            runningVMs: 3,
            discovered: ExeAccountIdentity(sshDestination: "exe.dev"),
            draft: ExeAccountIdentity(sshDestination: "exe.dev")
        ) == "3 running of 4 VMs")
        #expect(ExeAccountsSettingsView.loadedSummary(
            totalVMs: 1,
            runningVMs: 1,
            discovered: ExeAccountIdentity(
                sshDestination: "exe.dev",
                tagFilter: "dev, prod"
            ),
            draft: ExeAccountIdentity(
                sshDestination: " exe.dev ",
                tagFilter: "PROD,dev"
            )
        ) == "1 running of 1 VM tagged dev or prod")
    }

    @Test(
        "counts are never labeled with an identity discovery did not use",
        arguments: [
            ("exe.dev", "dev", "exe.dev", "prod", "Tags"),
            ("exe.dev", "dev", "exe.dev", "", "Tags"),
            ("exe.dev", "", "exe.dev", "dev", "Tags"),
            ("exe.dev", "dev", "exe.dev", "dev, prod", "Tags"),
            ("exe.dev", "", "other.exe.dev", "", "Destination"),
            ("exe.dev", "dev", "other.exe.dev", "dev", "Destination"),
            ("exe.dev", "dev", "other.exe.dev", "prod", "Destination and tags"),
        ]
    )
    @MainActor
    func editedAccountsDoNotRelabelStaleCounts(
        discoveredDestination: String,
        discoveredTags: String,
        draftDestination: String,
        draftTags: String,
        subject: String
    ) {
        #expect(ExeAccountsSettingsView.loadedSummary(
            totalVMs: 1,
            runningVMs: 1,
            discovered: ExeAccountIdentity(
                sshDestination: discoveredDestination,
                tagFilter: discoveredTags
            ),
            draft: ExeAccountIdentity(
                sshDestination: draftDestination,
                tagFilter: draftTags
            )
        ) == "\(subject) changed. Select Connect and Discover VMs to apply.")
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
        let connectedAccount = ExeAccount(
            configKey: "connected",
            name: "Connected",
            sshDestination: "connected.exe.dev"
        )
        var probedAccounts: [String] = []
        let inventory = [ExeVMRecord(
            vmName: "build",
            sshDestination: "vm+build@exe.dev",
            status: "running"
        )]
        let runner = ExeAccountConnectionRunner(
            pendingTrust: { account in
                if account == trustFailure {
                    return .failure(.message("Trust failed"))
                }
                return .success(.none)
            },
            probe: { account in
                probedAccounts.append(account.id)
                if account == probeFailure {
                    return .failed("Probe failed")
                }
                return .connected(inventory)
            }
        )
        let operation = ExeAccountConnectionOperation(
            accounts: [trustFailure, probeFailure, connectedAccount]
        )

        let result = await runner.run(operation, isCurrent: { true })
        guard case let .refresh(accounts, prefetchedVMs, messages) = result else {
            Issue.record("Expected eligible accounts to refresh")
            return
        }

        #expect(accounts == [connectedAccount])
        #expect(messages[trustFailure.id] == "Trust failed")
        #expect(messages[probeFailure.id] == "Probe failed")
        #expect(prefetchedVMs[connectedAccount.configKey] == inventory)
        #expect(probedAccounts == [probeFailure.id, connectedAccount.id])
    }
}
