import Foundation
import GhosthubTransport
import GhosthubUI

/// The command failed or its output could not be read.
struct KwtAgentHookError: Error, Equatable, LocalizedError {
    var action: KwtAgentHookClient.Action
    var host: String

    var errorDescription: String? {
        switch action {
        case .status: "Could not read agent hook status on \(host)."
        case .install: "Agent hook setup failed on \(host)."
        }
    }
}

/// Runs `kwt agent-hook` with the exact kwt Ghosthub manages for a host.
/// Hooks record agent state on tmux panes; see `kwt agent-hook --help`.
struct KwtAgentHookClient: Sendable {
    enum Action: String, Sendable {
        case status
        case install
    }

    typealias LocalRunner = @Sendable (_ command: String) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ connectionArguments: [String], _ command: String
    ) -> AccountCommandOutput

    private static let jsonMarker = "GHOSTHUB_KWT_AGENT_HOOK_JSON\n"
    private let localRunner: LocalRunner
    private let remoteRunner: RemoteRunner
    private let localBinaryPath: String?
    private let remoteBinaryRevision: String?
    private let commandLease: KwtSSHCommandLease

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        localBinaryPath: String? = KwtBinaryLocator.bundledPath(),
        remoteBinaryRevision: String? = KwtBinaryLocator.bundledRemoteRevision(),
        commandLease: KwtSSHCommandLease? = nil
    ) {
        self.localRunner = localRunner ?? { command in
            AccountCommandRunner.runLoginShell(
                shell: AccountCommandRunner.loginShell(),
                command: command,
                timeout: 30
            )
        }
        self.remoteRunner = remoteRunner ?? { host, arguments, command in
            AccountCommandRunner().runRemoteLoginShell(
                host: host,
                connectionArguments: arguments,
                command: command,
                timeout: 30
            )
        }
        self.commandLease = commandLease ?? .unlessInjected(remoteRunner != nil)
        self.localBinaryPath = localBinaryPath
        self.remoteBinaryRevision = remoteBinaryRevision
    }

    func run(_ action: Action, on host: CommandHost) async throws -> [AgentHookSetupStatus] {
        let result: (status: Int32, stdout: String)
        switch host {
        case .local:
            let command = Self.command(
                action,
                binaryPrelude: KwtBinaryLocator.commandPrelude(exactPath: localBinaryPath)
            )
            let localRunner = localRunner
            result = await BlockingTask.run(priority: .userInitiated) {
                localRunner(command)
            }
        case let .ssh(info):
            let command = Self.command(
                action,
                binaryPrelude: KwtBinaryLocator.remoteCommandPrelude(revision: remoteBinaryRevision)
            )
            let remoteRunner = remoteRunner
            let output = try await commandLease.withConnection(on: host) { connection in
                await commandLease.runCommand(using: connection) { arguments in
                    remoteRunner(info, arguments, command)
                }
            }
            result = (output.status, output.stdout)
        }
        return try Self.decode(result, action: action, hostLabel: host.displayName)
    }

    static func command(_ action: Action, binaryPrelude: String) -> String {
        binaryPrelude
            + "printf 'GHOSTHUB_KWT_AGENT_HOOK_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" agent-hook \(action.rawValue) --json"
    }

    static func decode(
        _ result: (status: Int32, stdout: String),
        action: Action,
        hostLabel: String
    ) throws -> [AgentHookSetupStatus] {
        let output = result.stdout.replacingOccurrences(of: "\r\n", with: "\n")
        guard result.status == 0,
              let marker = output.range(of: jsonMarker, options: .backwards),
              let response = try? JSONDecoder().decode(
                  Response.self, from: Data(output[marker.upperBound...].utf8)
              )
        else {
            throw KwtAgentHookError(action: action, host: hostLabel)
        }
        return response.agents
    }

    private struct Response: Decodable {
        var agents: [AgentHookSetupStatus]
    }
}
