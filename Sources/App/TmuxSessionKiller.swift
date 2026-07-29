import Foundation
import GhosthubTmux
import GhosthubUI

struct TmuxSessionIdentity: Equatable, Sendable {
    let serverPID: String
    let sessionID: String
    let createdAt: String
}

enum TmuxSessionKillError: Error, Equatable, LocalizedError {
    case commandFailed(host: String, session: String, status: Int32)
    case hostChanged(session: String)
    case identityCommandFailed(host: String, session: String, status: Int32)
    case identityUnavailable(host: String, session: String)
    case sessionChanged(host: String, session: String)
    case sessionNotRunning(host: String, session: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(host, session, status):
            return "tmux could not kill session “\(session)” on \(host)"
                + " (status \(status)). Refresh the host and try again."
        case let .hostChanged(session):
            return "The connection for session “\(session)” changed after"
                + " confirmation. Review the host and try again."
        case let .identityCommandFailed(host, session, status):
            return "Tmux could not verify session “\(session)” on \(host)"
                + " (status \(status)). Refresh the host and try again."
        case let .identityUnavailable(host, session):
            return "Tmux returned an invalid identity for session “\(session)”"
                + " on \(host). Refresh the host and try again."
        case let .sessionChanged(host, session):
            return "Session “\(session)” on \(host) was replaced after"
                + " confirmation. Refresh the host and review the new session."
        case let .sessionNotRunning(host, session):
            return "Session “\(session)” is no longer known to be running on"
                + " \(host). Refresh the host and try again."
        }
    }
}

struct TmuxSessionKiller: Sendable {
    private static let identityMismatchMarker =
        "GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH"
    private static let identityMarker =
        "GHOSTHUB_TMUX_SESSION_IDENTITY\t"
    private static let absenceMarker =
        "GHOSTHUB_TMUX_SESSION_ABSENT"

    typealias PathResolver = @Sendable (TmuxHost)
        -> Result<String, TmuxBinaryError>
    typealias Runner = @Sendable (TmuxHost, String)
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
                TmuxBinaryResolver.runLoginShell(
                    shell: TmuxBinaryResolver.loginShell(),
                    command: command,
                    timeout: 15
                )
            case let .ssh(info):
                TmuxBinaryResolver.runRemoteLoginShell(
                    host: info,
                    command: command,
                    timeout: 15
                )
            }
        }
    }

    func kill(
        _ selection: WorkspaceTmuxSessionSelection,
        expectedIdentity: TmuxSessionIdentity,
        on host: TmuxHost
    ) async throws {
        guard Self.isNumericIdentity(expectedIdentity.serverPID),
              Self.isSessionID(expectedIdentity.sessionID),
              Self.isSessionCreatedAt(expectedIdentity.createdAt)
        else {
            throw TmuxSessionKillError.sessionNotRunning(
                host: host.displayName,
                session: selection.name
            )
        }
        let tmuxPath = try pathResolver(host).get()
        let command = Self.command(
            tmuxPath: tmuxPath,
            sessionName: selection.name,
            socketName: selection.socketName,
            expectedIdentity: expectedIdentity,
            platform: Self.platform(for: host)
        )
        let runner = runner
        let result = await Task.detached(priority: .userInitiated) {
            runner(host, command)
        }.value
        guard result.status == 0 else {
            throw TmuxSessionKillError.commandFailed(
                host: host.displayName,
                session: selection.name,
                status: result.status
            )
        }
        guard !result.stdout.contains(Self.identityMismatchMarker) else {
            throw TmuxSessionKillError.sessionChanged(
                host: host.displayName,
                session: selection.name
            )
        }
    }

    func sessionIdentity(
        _ selection: WorkspaceTmuxSessionSelection,
        on host: TmuxHost
    ) async throws -> TmuxSessionIdentity {
        let tmuxPath = try pathResolver(host).get()
        let command = Self.identityCommand(
            tmuxPath: tmuxPath,
            sessionName: selection.name,
            socketName: selection.socketName,
            platform: Self.platform(for: host)
        )
        let runner = runner
        let result = await Task.detached(priority: .userInitiated) {
            runner(host, command)
        }.value
        guard result.status == 0 else {
            throw TmuxSessionKillError.identityCommandFailed(
                host: host.displayName,
                session: selection.name,
                status: result.status
            )
        }
        if result.stdout.split(whereSeparator: \.isNewline).contains(
            Substring(Self.absenceMarker)
        ) {
            throw TmuxSessionKillError.sessionNotRunning(
                host: host.displayName,
                session: selection.name
            )
        }
        guard let identity = Self.parseIdentity(result.stdout) else {
            throw TmuxSessionKillError.identityUnavailable(
                host: host.displayName,
                session: selection.name
            )
        }
        return identity
    }

    static func command(
        tmuxPath: String,
        sessionName: String,
        socketName: String?,
        expectedIdentity: TmuxSessionIdentity,
        platform: SSHHostInfo.Platform = .posix
    ) -> String {
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
            "#{&&:#{==:#{pid},\(expectedIdentity.serverPID)},"
                + "#{&&:#{==:#{session_id},\(expectedIdentity.sessionID)},"
                + "#{==:#{session_created},\(expectedIdentity.createdAt)}}}",
            "kill-session -t \(shellQuotedCommandArgument(target))",
            "display-message -p "
                + shellQuotedCommandArgument(identityMismatchMarker),
        ])
        if platform == .windows {
            arguments[arguments.count - 2] =
                "kill-session -t \(expectedIdentity.sessionID)"
            arguments[arguments.count - 1] =
                "display-message -p \(identityMismatchMarker)"
            return powerShellCommand(arguments)
        }
        return arguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
    }

    private static func identityCommand(
        tmuxPath: String,
        sessionName: String,
        socketName: String?,
        platform: SSHHostInfo.Platform
    ) -> String {
        var baseArguments = [tmuxPath]
        if let socketName {
            baseArguments.append(contentsOf: ["-L", socketName])
        }
        let target = "=\(sessionName):"
        let hasSessionArguments = baseArguments + [
            "has-session",
            "-t",
            target,
        ]
        let identityArguments = baseArguments + [
            "display-message",
            "-p",
            "-t",
            target,
            identityMarker + "#{pid}\t#{session_id}\t#{session_created}",
        ]
        if platform == .windows {
            return identityPowerShellCommand(
                hasSessionArguments: hasSessionArguments,
                identityArguments: identityArguments
            )
        }
        let hasSessionCommand = hasSessionArguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        let identityCommand = identityArguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        return "\(hasSessionCommand); status=$?; "
            + "if [ \"$status\" -eq 1 ]; then printf '%s\\n' "
            + "\(shellQuotedCommandArgument(absenceMarker)); exit 0; fi; "
            + "[ \"$status\" -eq 0 ] || exit \"$status\"; "
            + identityCommand
    }

    private static func identityPowerShellCommand(
        hasSessionArguments: [String],
        identityArguments: [String]
    ) -> String {
        """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        & \(hasSessionArguments.map(powerShellEncodedArgument).joined(separator: " "))
        $status = $LASTEXITCODE
        if ($status -eq 1) {
            Write-Output \(powerShellEncodedArgument(absenceMarker))
            exit 0
        }
        if ($status -ne 0) {
            exit $status
        }
        & \(identityArguments.map(powerShellEncodedArgument).joined(separator: " "))
        exit $LASTEXITCODE
        """
    }

    private static func powerShellCommand(_ arguments: [String]) -> String {
        """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        & \(arguments.map(powerShellEncodedArgument).joined(separator: " "))
        exit $LASTEXITCODE
        """
    }

    private static func platform(
        for host: TmuxHost
    ) -> SSHHostInfo.Platform {
        switch host {
        case .local:
            .posix
        case let .ssh(info):
            info.platform
        }
    }

    static func isSessionCreatedAt(_ value: String) -> Bool {
        isNumericIdentity(value)
    }

    static func isNumericIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte >= 48 && byte <= 57
        }
    }

    static func isSessionID(_ value: String) -> Bool {
        value.utf8.first == 36
            && value.utf8.dropFirst().allSatisfy { byte in
                byte >= 48 && byte <= 57
            }
            && value.utf8.count > 1
    }

    private static func parseIdentity(
        _ output: String
    ) -> TmuxSessionIdentity? {
        let markedLine = output
            .split(whereSeparator: \.isNewline)
            .reversed()
            .map(String.init)
            .first { $0.hasPrefix(identityMarker) }
        guard let markedLine else { return nil }
        let fields = markedLine.dropFirst(identityMarker.count).split(
            separator: "\t",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3 else { return nil }
        let identity = TmuxSessionIdentity(
            serverPID: String(fields[0]),
            sessionID: String(fields[1]),
            createdAt: String(fields[2])
        )
        guard isNumericIdentity(identity.serverPID),
              isSessionID(identity.sessionID),
              isSessionCreatedAt(identity.createdAt)
        else { return nil }
        return identity
    }
}
