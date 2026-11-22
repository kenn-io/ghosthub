import Foundation
import GhosthubTmux
import GhosthubTransport
import GhosthubWorkspace

/// The command failed or its output could not be read.
struct KwtSessionError: Error, Equatable, LocalizedError {
    var host: String

    var errorDescription: String? {
        "kwt could not update saved tmux sessions on \(host)."
    }
}

/// Runs `kwt session` with the exact kwt Ghosthub manages for a host. kwt
/// saves tmux sessions as they change, so it can restore them, with their
/// Claude Code and Codex conversations, after the server stops.
struct KwtSessionClient: Sendable {
    typealias LocalRunner = @Sendable (_ command: String) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ connectionArguments: [String], _ command: String
    ) -> AccountCommandOutput

    private static let jsonMarker = "GHOSTHUB_KWT_SESSION_JSON\n"
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
        // Restore waits a few seconds for panes to start their programs.
        self.localRunner = localRunner ?? { command in
            AccountCommandRunner.runLoginShell(
                shell: AccountCommandRunner.loginShell(),
                command: command,
                timeout: 60
            )
        }
        self.remoteRunner = remoteRunner ?? { host, arguments, command in
            AccountCommandRunner().runRemoteLoginShell(
                host: host,
                connectionArguments: arguments,
                command: command,
                timeout: 60
            )
        }
        self.commandLease = commandLease ?? .unlessInjected(remoteRunner != nil)
        self.localBinaryPath = localBinaryPath
        self.remoteBinaryRevision = remoteBinaryRevision
    }

    /// Saves the host's tmux sessions and lists the ones it can restore.
    func savedSessions(on host: CommandHost) async throws -> [SavedTmuxSession] {
        let result = try await run(["snapshot", "--json"], on: host)
        guard result.status == 0 else { throw KwtSessionError(host: host.displayName) }
        return try decode(Listing.self, from: result.stdout, host: host).entries
    }

    /// kwt exits non-zero when a session fails but still reports every one.
    func restore(_ ids: [String], on host: CommandHost) async throws -> TmuxRestoreReport {
        let result = try await run(["restore", "--json"] + ids, on: host)
        return try decode(TmuxRestoreReport.self, from: result.stdout, host: host)
    }

    /// Deletes saved sessions without restoring them.
    func dismiss(_ ids: [String], on host: CommandHost) async throws {
        let result = try await run(["dismiss"] + ids, on: host)
        guard result.status == 0 else { throw KwtSessionError(host: host.displayName) }
    }

    /// Stops kwt offering a session killed on purpose for restore.
    func forget(
        socketName: String,
        identity: TmuxSessionIdentity,
        on host: CommandHost
    ) async throws {
        let result = try await run([
            "forget", "--socket-name", socketName,
            "--session-id", identity.sessionID,
            "--server-pid", identity.serverPID,
            "--created", identity.createdAt,
        ], on: host)
        guard result.status == 0 else { throw KwtSessionError(host: host.displayName) }
    }

    private func run(
        _ arguments: [String],
        on host: CommandHost
    ) async throws -> (status: Int32, stdout: String) {
        switch host {
        case .local:
            let command = Self.command(
                arguments,
                binaryPrelude: KwtBinaryLocator.commandPrelude(exactPath: localBinaryPath)
            )
            let localRunner = localRunner
            return await BlockingTask.run(priority: .utility) {
                localRunner(command)
            }
        case let .ssh(info):
            let command = Self.command(
                arguments,
                binaryPrelude: KwtBinaryLocator.remoteCommandPrelude(revision: remoteBinaryRevision)
            )
            let remoteRunner = remoteRunner
            let output = try await commandLease.withConnection(on: host) { connection in
                await commandLease.runCommand(using: connection) { arguments in
                    remoteRunner(info, arguments, command)
                }
            }
            return (output.status, output.stdout)
        }
    }

    static func command(_ arguments: [String], binaryPrelude: String) -> String {
        binaryPrelude
            + "printf 'GHOSTHUB_KWT_SESSION_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" session "
            + arguments.map(shellQuotedCommandArgument).joined(separator: " ")
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from stdout: String,
        host: CommandHost
    ) throws -> Value {
        let output = stdout.replacingOccurrences(of: "\r\n", with: "\n")
        guard let marker = output.range(of: Self.jsonMarker, options: .backwards),
              let value = try? JSONDecoder().decode(
                  type, from: Data(output[marker.upperBound...].utf8)
              )
        else {
            throw KwtSessionError(host: host.displayName)
        }
        return value
    }

    private struct Listing: Decodable {
        var entries: [SavedTmuxSession]
    }
}
