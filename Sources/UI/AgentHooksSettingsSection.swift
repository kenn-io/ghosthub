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
    /// Changes when the status should load again for the same host, such as
    /// after a connection check approved its host key or sign-in.
    var refreshID = 0
    let load: AgentHookSetup.Operation
    let install: AgentHookSetup.Operation

    @State private var setup = AgentHookSetup()
    @State private var retries = 0

    private var statuses: [AgentHookSetupStatus]? {
        setup.statuses
    }

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
            } else if setup.errorMessage == nil {
                ProgressView()
                    .controlSize(.small)
            }

            if agents.contains(where: { $0.agent == "codex" && $0.installed }) {
                Text("Codex: open /hooks once to trust new hooks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = setup.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

                if statuses == nil, !setup.isInstalling {
                    Button("Retry") { retries += 1 }
                        .accessibilityIdentifier("retry-agent-hooks")
                }
            }

            if needsInstall {
                Button(setup.isInstalling ? "Installing\u{2026}" : "Install Hooks") {
                    Task { await setup.install(host, using: install) }
                }
                .disabled(setup.isInstalling)
                .accessibilityIdentifier("install-agent-hooks")
            }
        }
        .task(id: LoadRequest(
            connection: AgentHookConnection(host),
            refreshID: refreshID,
            retries: retries
        )) {
            await setup.load(host, using: load)
        }
    }

    private struct LoadRequest: Equatable {
        var connection: AgentHookConnection
        var refreshID: Int
        var retries: Int
    }

    static func stateLabel(_ status: AgentHookSetupStatus) -> String {
        if status.current {
            return "Installed"
        }
        return status.installed ? "Update available" : "Not installed"
    }
}
