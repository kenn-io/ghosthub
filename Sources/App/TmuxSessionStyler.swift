import GhosthubTransport
import Foundation
import GhosthubTmux
import GhosthubUI

enum TmuxSessionStyleError: Error, Equatable, LocalizedError {
    case unsupportedHost(host: String, session: String)
    case commandFailed(host: String, session: String, status: Int32)
    case sessionChanged(host: String, session: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedHost(host, session):
            return "Tmux session theming is unavailable for session"
                + " “\(session)” on \(host)."
        case let .commandFailed(host, session, status):
            return "Tmux could not apply the theme to session “\(session)”"
                + " on \(host) (status \(status)). Refresh the host and try again."
        case let .sessionChanged(host, session):
            return "Session “\(session)” on \(host) was replaced before"
                + " its theme could be applied. Refresh the host and try again."
        }
    }
}

struct TmuxSessionStyler: Sendable {
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

    func apply(
        _ style: TmuxPresentationStyle,
        to selection: WorkspaceTmuxSessionSelection,
        expectedIdentity: TmuxSessionIdentity,
        on host: CommandHost
    ) async throws {
        if case let .ssh(info) = host, info.platform == .windows {
            throw TmuxSessionStyleError.unsupportedHost(
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
            let tmuxPath = try pathResult.get()
            let command = TmuxPresentationCommand(
                sessionName: selection.name,
                socketName: selection.socketName,
                style: style
            ).applyCommand(
                tmuxPath: tmuxPath,
                expectedIdentity: expectedIdentity
            )
            return await commandLease.runCommand(using: connection) { _ in
                runner(host, connectionArguments, command)
            }
        }
        guard !result.stdout.contains(
            TmuxPresentationCommand.identityMismatchMarker
        ) else {
            throw TmuxSessionStyleError.sessionChanged(
                host: host.displayName,
                session: selection.name
            )
        }
        guard result.status == 0 else {
            throw TmuxSessionStyleError.commandFailed(
                host: host.displayName,
                session: selection.name,
                status: result.status
            )
        }
    }
}
