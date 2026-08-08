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

    private let pathResolver: PathResolver
    private let runner: Runner

    init(
        pathResolver: PathResolver? = nil,
        runner: Runner? = nil
    ) {
        self.pathResolver = pathResolver ?? { host in
            let resolver = TmuxBinaryResolver()
            switch host {
            case .local:
                return resolver.resolveTmuxPath()
            case let .ssh(info):
                return resolver.resolveTmuxPath(on: info)
            }
        }
        self.runner = runner ?? { host, command in
            switch host {
            case .local:
                AccountCommandRunner.runLoginShell(
                    shell: AccountCommandRunner.loginShell(),
                    command: command,
                    timeout: 15
                )
            case let .ssh(info):
                AccountCommandRunner.runRemoteLoginShell(
                    host: info,
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
        let tmuxPath = try pathResolver(host).get()
        let command = TmuxPresentationCommand(
            sessionName: selection.name,
            socketName: selection.socketName,
            style: style
        ).applyCommand(
            tmuxPath: tmuxPath,
            expectedIdentity: expectedIdentity
        )
        let runner = runner
        let result = await Task.detached(priority: .userInitiated) {
            runner(host, command)
        }.value
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
