import GhosthubSettings
import SwiftUI

/// Every host's agent hooks in one place, with the setting that keeps them
/// current.
struct AgentHooksOverviewSection: View {
    @ObservedObject var store: SettingsStore
    let maintainer: AgentHookMaintainer

    private var targets: [AgentHookTarget] {
        AgentHookTarget.all(sshHosts: store.sshHosts)
    }

    private var isBusy: Bool {
        targets.contains { target in
            switch maintainer.phases[target.id] {
            case .checking, .installing: true
            default: false
            }
        }
    }

    private var anyFailed: Bool {
        targets.contains { target in
            if case .failed = maintainer.phases[target.id] {
                return true
            }
            return false
        }
    }

    private var codexInstalled: Bool {
        targets.contains { target in
            guard case let .ready(statuses) = maintainer.phases[target.id] else { return false }
            return statuses.contains { $0.agent == "codex" && $0.installed }
        }
    }

    var body: some View {
        settingsSection("Agent Hooks") {
            Toggle(
                "Install and update agent hooks automatically",
                isOn: Binding(
                    get: { store.autoInstallAgentHooks },
                    set: { store.setAutoInstallAgentHooks($0) }
                )
            )
            .accessibilityIdentifier("auto-install-agent-hooks")

            Text("Edits each agent's user settings on this Mac and every macOS and Linux SSH host.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(targets) { target in
                    HStack(alignment: .firstTextBaseline) {
                        Text(target.name)
                        Spacer()
                        phaseText(maintainer.phases[target.id])
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.system(size: 12))
                }
            }
            .accessibilityIdentifier("agent-hook-hosts")

            if codexInstalled {
                Text("Codex: open /hooks once on each host to trust new hooks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack {
                if maintainer.hooksMissing(in: targets) {
                    Button("Install on All Hosts") {
                        Task { await maintainer.check(targets, installing: true) }
                    }
                    .accessibilityIdentifier("install-agent-hooks-everywhere")
                }
                if anyFailed {
                    Button("Check Again") {
                        Task { await maintainer.check(targets, installing: false) }
                    }
                }
            }
            .disabled(isBusy)
        }
        .task(id: targets) {
            await maintainer.check(
                targets.filter { maintainer.phases[$0.id] == nil },
                installing: false
            )
        }
    }

    @ViewBuilder
    private func phaseText(_ phase: AgentHookMaintainer.Phase?) -> some View {
        switch phase {
        case nil, .checking:
            Text("Checking\u{2026}").foregroundStyle(.secondary)
        case .installing:
            Text("Installing\u{2026}").foregroundStyle(.secondary)
        case let .failed(message):
            Text(message).foregroundStyle(.red)
        case let .ready(statuses):
            Text(Self.summary(statuses)).foregroundStyle(.secondary)
        }
    }

    /// One host's agents and their hook state, such as
    /// "Claude Code: Installed · Codex: Update available".
    static func summary(_ statuses: [AgentHookSetupStatus]) -> String {
        let agents = statuses.filter(\.available)
        guard !agents.isEmpty else { return "No supported agents" }
        return agents
            .map { "\($0.displayName): \(AgentHooksSettingsSection.stateLabel($0))" }
            .joined(separator: " · ")
    }
}
