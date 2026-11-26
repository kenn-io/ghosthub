import Combine
import Foundation
import GhosthubSettings
import GhosthubUI

/// Connects agent hook upkeep and the welcome sheet to the app's kwt.
@MainActor
enum AgentHookAutomation {
    private static var subscriptions: Set<AnyCancellable> = []

    /// Runs once per launch. With automatic hooks on, every saved and
    /// discovered host gets current hooks now, and each host added or
    /// discovered later gets them when it appears.
    static func start(
        isNewInstall: Bool,
        settings: SettingsStore = .shared,
        exeHosts: ExeVMInventoryStore = .shared,
        maintainer: AgentHookMaintainer = .shared,
        presenter: OnboardingPresenter = .shared
    ) {
        guard subscriptions.isEmpty else { return }
        let client = KwtAgentHookClient()
        let provision: @Sendable (SSHHost) async throws -> Void = { host in
            try await KwtRemoteProvisioningCoordinator.shared.ensureInstalled(on: host)
        }
        maintainer.status = { host in
            await client.run(.status, on: host, provision: provision)
        }
        maintainer.install = { host in
            await client.run(.install, on: host, provision: provision)
        }
        let discovered = exeHosts.$hosts
            .map { $0.map(\.sshHost) }
            .removeDuplicates()
        discovered
            .sink { maintainer.discoveredHosts = $0 }
            .store(in: &subscriptions)
        settings.$autoInstallAgentHooks
            .combineLatest(settings.$sshHosts, discovered)
            .sink { enabled, hosts, discovered in
                guard enabled else { return }
                let targets = AgentHookTarget.all(sshHosts: hosts, discovered: discovered)
                Task { @MainActor in
                    await maintainer.maintain(targets)
                }
            }
            .store(in: &subscriptions)
        Task {
            await presenter.decideAtLaunch(
                settings: settings,
                maintainer: maintainer,
                isNewInstall: isNewInstall,
                discovered: {
                    await exeHosts.listed(settings.exeAccounts, timeout: .seconds(60))
                }
            )
        }
    }
}
