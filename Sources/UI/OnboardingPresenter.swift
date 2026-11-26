import Foundation
import GhosthubSettings
import Observation

/// Shows the welcome sheet in exactly one workspace window.
@MainActor
@Observable
public final class OnboardingPresenter {
    public static let shared = OnboardingPresenter()

    public private(set) var isPending = false
    private var owner: UUID?

    public init() {}

    /// Asks for the sheet. A nil window lets the first window that looks
    /// claim it, as at launch.
    public func present(in window: UUID? = nil) {
        isPending = true
        owner = window
    }

    /// Whether `window` shows the sheet. The first window to ask while it
    /// is unclaimed takes it.
    public func claim(_ window: UUID) -> Bool {
        guard isPending else { return false }
        if owner == nil {
            owner = window
        }
        return owner == window
    }

    /// The window closed; another can claim the sheet.
    public func release(_ window: UUID) {
        if owner == window {
            owner = nil
        }
    }

    public func finish() {
        isPending = false
        owner = nil
    }

    /// Decides at launch whether to welcome the person. A new install is
    /// always welcomed. Someone who used Ghosthub before is welcomed only
    /// when a host has an agent without current hooks, since the sheet is
    /// where they learn Ghosthub can install them. A failed check decides
    /// nothing, so the next launch checks again.
    public func decideAtLaunch(
        settings: SettingsStore,
        maintainer: AgentHookMaintainer,
        isNewInstall: Bool
    ) async {
        guard !settings.onboardingCompleted else { return }
        if settings.autoInstallAgentHooks {
            settings.setOnboardingCompleted(true)
            return
        }
        if isNewInstall {
            present()
            return
        }
        let targets = maintainer.targets(sshHosts: settings.sshHosts)
        await maintainer.check(targets, installing: false)
        if maintainer.hooksMissing(in: targets) {
            present()
        } else if maintainer.checked(targets) {
            settings.setOnboardingCompleted(true)
        }
    }
}
