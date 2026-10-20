import GhosthubTransport
import Foundation
import GhosthubTmux
import GhosthubUI

enum TmuxSessionRenameError: Error, Equatable, LocalizedError {
    case unsupportedHost(host: String, session: String)
    case sessionNotRunning(host: String, session: String)
    case nameInUse(host: String, name: String)
    case nameOwnedByKwt(host: String, name: String)
    case sessionConnecting(session: String)
    case sessionChanged(host: String, session: String)
    case commandFailed(
        host: String,
        session: String,
        status: Int32,
        message: String
    )

    var errorDescription: String? {
        switch self {
        case let .unsupportedHost(host, session):
            return "Renaming tmux session “\(session)” is unavailable on"
                + " \(host)."
        case let .sessionNotRunning(host, session):
            return "Session “\(session)” is no longer known to be running on"
                + " \(host). Refresh the host and try again."
        case let .nameInUse(host, name):
            return "A tmux session named “\(name)” already exists on \(host)."
        case let .nameOwnedByKwt(host, name):
            return "kwt owns the session name “\(name)” on \(host). Names"
                + " starting with kwt-wt- or kwt-workspace- belong to kwt."
        case .sessionConnecting:
            return "The session is still connecting. Try again in a moment."
        case let .sessionChanged(host, session):
            return "Session “\(session)” on \(host) was replaced or removed"
                + " before it could be renamed. Refresh the host and try again."
        case let .commandFailed(host, session, status, message):
            let detail = message.isEmpty ? "" : " \(message)."
            return "Tmux could not rename session “\(session)” on \(host)"
                + " (status \(status)).\(detail)"
        }
    }
}

struct TmuxSessionRenamer: Sendable {
    static let identityMismatchMarker =
        "GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH"

    typealias PathResolver = @Sendable (CommandHost)
        -> Result<String, TmuxBinaryError>
    typealias Runner = @Sendable (CommandHost, String)
        -> (status: Int32, stdout: String)

    private typealias RoutedPathResolver = @Sendable (
        CommandHost, [String]?
    ) -> Result<String, TmuxBinaryError>
    private typealias RoutedRunner = @Sendable (
        CommandHost, [String]?, String
    ) -> AccountCommandOutput

    private let pathResolver: RoutedPathResolver
    private let runner: RoutedRunner
    private let commandLease: KwtSSHCommandLease

    init(
        pathResolver: PathResolver? = nil,
        runner: Runner? = nil,
        commandLease: KwtSSHCommandLease? = nil
    ) {
        self.commandLease = commandLease ?? .unlessInjected(
            pathResolver != nil || runner != nil
        )
        self.pathResolver = { host, connectionArguments in
            if let pathResolver {
                return pathResolver(host)
            }
            let resolver = TmuxBinaryResolver()
            switch host {
            case .local:
                return resolver.resolveTmuxPath()
            case let .ssh(info):
                return resolver.resolveTmuxPath(
                    on: info,
                    sshConnectionArguments: connectionArguments ?? []
                )
            }
        }
        self.runner = { host, connectionArguments, command in
            if let runner {
                let output = runner(host, command)
                return AccountCommandOutput(
                    status: output.status,
                    stdout: output.stdout,
                    stderr: ""
                )
            }
            switch host {
            case .local:
                let output = AccountCommandRunner.runLoginShell(
                    shell: AccountCommandRunner.loginShell(),
                    command: command,
                    timeout: 15
                )
                return AccountCommandOutput(
                    status: output.status,
                    stdout: output.stdout,
                    stderr: ""
                )
            case let .ssh(info):
                return AccountCommandRunner().runRemoteLoginShell(
                    host: info,
                    connectionArguments: connectionArguments ?? [],
                    command: command,
                    timeout: 15
                )
            }
        }
    }

    /// Renames the session only while its target still has the reviewed
    /// server, session ID, and creation time.
    func rename(
        _ selection: WorkspaceTmuxSessionSelection,
        to newName: String,
        expectedIdentity: TmuxSessionIdentity,
        on host: CommandHost
    ) async throws {
        if case let .ssh(info) = host, info.platform == .windows {
            throw TmuxSessionRenameError.unsupportedHost(
                host: host.displayName,
                session: selection.name
            )
        }
        let pathResolver = pathResolver
        let runner = runner
        let result = try await commandLease.withConnection(on: host) {
            connection in
            let connectionArguments = connection?.arguments
            let pathResult = await BlockingTask.run(
                priority: .userInitiated
            ) {
                pathResolver(host, connectionArguments)
            }
            if case let .failure(.sshConnectionFailed(_, classification)) =
                pathResult,
                classification.connectionUnusable {
                await connection?.invalidate()
            }
            let command = Self.command(
                tmuxPath: try pathResult.get(),
                sessionName: selection.name,
                newName: newName,
                socketName: selection.socketName,
                expectedIdentity: expectedIdentity
            )
            return await commandLease.runCommand(using: connection) { _ in
                runner(host, connectionArguments, command)
            }
        }
        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(Self.identityMismatchMarker) else {
            throw TmuxSessionRenameError.sessionChanged(
                host: host.displayName,
                session: selection.name
            )
        }
        guard result.status == 0 else {
            throw TmuxSessionRenameError.commandFailed(
                host: host.displayName,
                session: selection.name,
                status: result.status,
                message: lines.filter { !$0.isEmpty }.joined(separator: " ")
            )
        }
    }

    static func command(
        tmuxPath: String,
        sessionName: String,
        newName: String,
        socketName: String?,
        expectedIdentity: TmuxSessionIdentity
    ) -> String {
        // A trailing colon makes tmux treat `=name:` as an exact session
        // target instead of accepting a session-name prefix.
        let target = "=\(sessionName):"
        var arguments = [tmuxPath]
        if let socketName {
            arguments.append(contentsOf: ["-L", socketName])
        }
        arguments.append(contentsOf: [
            "if-shell",
            "-F",
            "-t",
            target,
            expectedIdentity.formatCondition,
            "rename-session -t \(shellQuotedCommandArgument(target)) "
                + shellQuotedCommandArgument(newName),
            "display-message -p "
                + shellQuotedCommandArgument(identityMismatchMarker),
        ])
        return arguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ") + " 2>&1"
    }
}
