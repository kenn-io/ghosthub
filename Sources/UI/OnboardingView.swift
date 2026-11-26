import GhosthubSettings
import SwiftUI

/// The welcome sheet: what Ghosthub needs from each host, and the one
/// choice that changes other machines' settings.
struct OnboardingView: View {
    let settingsStore: SettingsStore
    let addHost: () -> Void
    let finish: () -> Void

    @State private var autoInstallAgentHooks: Bool

    init(
        settingsStore: SettingsStore,
        addHost: @escaping () -> Void,
        finish: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.addHost = addHost
        self.finish = finish
        // A first welcome suggests the setting; a reopened one shows it.
        _autoInstallAgentHooks = State(
            initialValue: settingsStore.onboardingCompleted
                ? settingsStore.autoInstallAgentHooks
                : true
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Welcome to Ghosthub")
                .font(.system(size: 22, weight: .bold))

            step("Hosts", systemImage: "desktopcomputer") {
                Text("This Mac is ready. Add Macs and Linux machines you reach over SSH.")
                Button("Add SSH Host\u{2026}") {
                    apply()
                    addHost()
                }
                .accessibilityIdentifier("onboarding-add-host")
            }

            step("Agent Hooks", systemImage: "bell.badge") {
                Text(
                    "Hooks let Ghosthub show which Claude Code, Codex, and"
                        + " Antigravity agents need you, notify you, and resume"
                        + " their conversations after a reboot."
                )
                Toggle(
                    "Install and update agent hooks automatically",
                    isOn: $autoInstallAgentHooks
                )
                .accessibilityIdentifier("onboarding-auto-install-hooks")
                Text(
                    "Edits each agent's user settings on this Mac and your SSH"
                        + " hosts. Change it later in Settings → Agents."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Get Started") {
                    apply()
                    finish()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-get-started")
            }
        }
        .padding(28)
        .frame(width: 540)
    }

    private func apply() {
        settingsStore.setAutoInstallAgentHooks(autoInstallAgentHooks)
        settingsStore.setOnboardingCompleted(true)
    }

    private func step<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                content()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
