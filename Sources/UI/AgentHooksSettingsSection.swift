import GhosthubSettings
import SwiftUI

/// One agent's hook installation on a host, as reported by
/// `kwt agent-hook status --json`.
public struct AgentHookSetupStatus: Decodable, Equatable, Sendable {
    public var agent: String
    public var displayName: String
    public var available: Bool
    public var installed: Bool
    public var current: Bool

    public init(
        agent: String,
        displayName: String,
        available: Bool,
        installed: Bool,
        current: Bool
    ) {
        self.agent = agent
        self.displayName = displayName
        self.available = available
        self.installed = installed
        self.current = current
    }

    private enum CodingKeys: String, CodingKey {
        case agent, available, installed, current
        case displayName = "display_name"
    }
}

/// Installs the kwt hooks that report agent attention for one host.
/// A nil host means this Mac.
struct AgentHooksSettingsSection: View {
    let host: SSHHost?
    let load: (SSHHost?) async -> Result<[AgentHookSetupStatus], HostProbeError>
    let install: (SSHHost?) async -> Result<[AgentHookSetupStatus], HostProbeError>

    @State private var statuses: [AgentHookSetupStatus]?
    @State private var errorMessage: String?
    @State private var isInstalling = false

    private var agents: [AgentHookSetupStatus] {
        (statuses ?? []).filter(\.available)
    }

    private var needsInstall: Bool {
        agents.contains { !$0.current }
    }

    var body: some View {
        settingsSection("Agent Hooks") {
            Text("Edits each agent's user settings on this host.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if statuses != nil {
                if agents.isEmpty {
                    Text("No supported agents found")
                        .font(.system(size: 12))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(agents, id: \.agent) { status in
                            HStack {
                                Text(status.displayName)
                                Spacer()
                                Text(Self.stateLabel(status))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                        }
                    }
                    .accessibilityIdentifier("agent-hook-statuses")
                }
            } else if errorMessage == nil {
                ProgressView()
                    .controlSize(.small)
            }

            if agents.contains(where: { $0.agent == "codex" && $0.installed }) {
                Text("Codex: open /hooks once to trust new hooks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if needsInstall {
                Button(isInstalling ? "Installing\u{2026}" : "Install Hooks") {
                    Task { await runInstall() }
                }
                .disabled(isInstalling)
                .accessibilityIdentifier("install-agent-hooks")
            }
        }
        .task(id: host?.id) {
            statuses = nil
            errorMessage = nil
            await apply(load(host))
        }
    }

    private func runInstall() async {
        isInstalling = true
        defer { isInstalling = false }
        errorMessage = nil
        await apply(install(host))
    }

    private func apply(_ result: Result<[AgentHookSetupStatus], HostProbeError>) {
        switch result {
        case let .success(loaded):
            statuses = loaded
        case let .failure(error):
            errorMessage = error.displayMessage
        }
    }

    static func stateLabel(_ status: AgentHookSetupStatus) -> String {
        if status.current {
            return "Installed"
        }
        return status.installed ? "Update available" : "Not installed"
    }
}
