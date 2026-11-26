import Combine
import Foundation
import GhosthubSettings
import GhosthubUI

/// Connects agent hook upkeep and the welcome sheet to the app's kwt.
@MainActor
enum AgentHookAutomation {
    private static var subscription: AnyCancellable?

    /// Runs once per launch. With automatic hooks on, every host gets
    /// current hooks now and each host added later gets them when it
    /// appears.
    static func start(
        isNewInstall: Bool,
        settings: SettingsStore = .shared,
        maintainer: AgentHookMaintainer = .shared,
        presenter: OnboardingPresenter = .shared
    ) {
        guard subscription == nil else { return }
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
        subscription = settings.$autoInstallAgentHooks
            .combineLatest(settings.$sshHosts)
            .sink { enabled, hosts in
                guard enabled else { return }
                Task { @MainActor in
                    await maintainer.maintain(AgentHookTarget.all(sshHosts: hosts))
                }
            }
        Task {
            await presenter.decideAtLaunch(
                settings: settings,
                maintainer: maintainer,
                isNewInstall: isNewInstall
            )
        }
    }
}
