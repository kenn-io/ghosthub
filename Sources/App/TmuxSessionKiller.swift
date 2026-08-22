import GhosthubTransport
import Foundation
import GhosthubTmux
import GhosthubUI

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

struct ReviewedTmuxSessionIdentity: Equatable, Sendable {
    let identity: TmuxSessionIdentity
    let routeIdentity: String?
}

struct TmuxSessionKiller: Sendable {
    private static let identityMismatchMarker =
        "GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH"
    private static let identityMarker =
        "GHOSTHUB_TMUX_SESSION_IDENTITY\t"
    static let diagnosticMarker = "GHOSTHUB_TMUX_DIAGNOSTIC\t"

    typealias PathResolver = @Sendable (CommandHost)
        -> Result<String, TmuxBinaryError>
    typealias Runner = @Sendable (CommandHost, String)
        -> (status: Int32, stdout: String)
    typealias OutputRunner = @Sendable (CommandHost, String)
        -> AccountCommandOutput
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
        outputRunner: OutputRunner? = nil,
        commandLease: KwtSSHCommandLease? = nil
    ) {
        self.commandLease = commandLease ?? .unlessInjected(
            pathResolver != nil || runner != nil || outputRunner != nil
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
            if let outputRunner {
                return outputRunner(host, command)
            }
            if let runner {
                let result = runner(host, command)
                return AccountCommandOutput(
                    status: result.status,
                    stdout: result.stdout,
                    stderr: ""
                )
            }
            switch host {
            case .local:
                let result = AccountCommandRunner.runLoginShell(
                    shell: AccountCommandRunner.loginShell(),
                    command: command,
                    timeout: 15
                )
                return AccountCommandOutput(
                    status: result.status,
                    stdout: result.stdout,
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

    /// Borrows one lease for a remote host when the caller has none.
    private func withConnection<Value: Sendable>(
        _ sshConnectionArguments: [String]?,
        on host: CommandHost,
        operation: @escaping @Sendable (
            [String]?, KwtSSHConnection?
        ) async throws -> Value
    ) async throws -> Value {
        if sshConnectionArguments == nil, host.isRemote {
            return try await commandLease.withConnection(on: host) {
                connection in
                try await operation(connection?.arguments, connection)
            }
        }
        return try await operation(sshConnectionArguments, nil)
    }

    private func resolveTmuxPath(
        on host: CommandHost,
        sshConnectionArguments: [String]?,
        connection: KwtSSHConnection?
    ) async throws -> String {
        let result = pathResolver(host, sshConnectionArguments)
        if case let .failure(.sshConnectionFailed(_, classification)) = result,
           classification.connectionUnusable {
            await connection?.invalidate()
        }
        return try result.get()
    }

    func kill(
        _ selection: WorkspaceTmuxSessionSelection,
        expectedIdentity: TmuxSessionIdentity,
        on host: CommandHost,
        sshConnectionArguments: [String]? = nil
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
        if sshConnectionArguments == nil, host.isRemote {
            try await commandLease.withConnection(on: host) { connection in
                try await killWithArguments(
                    selection,
                    expectedIdentity: expectedIdentity,
                    on: host,
                    sshConnectionArguments: connection?.arguments,
                    connection: connection
                )
            }
        } else {
            try await killWithArguments(
                selection,
                expectedIdentity: expectedIdentity,
                on: host,
                sshConnectionArguments: sshConnectionArguments,
                connection: nil
            )
        }
    }

    private func killWithArguments(
        _ selection: WorkspaceTmuxSessionSelection,
        expectedIdentity: TmuxSessionIdentity,
        on host: CommandHost,
        sshConnectionArguments: [String]?,
        connection: KwtSSHConnection?
    ) async throws {
        let tmuxPath = try await resolveTmuxPath(
            on: host,
            sshConnectionArguments: sshConnectionArguments,
            connection: connection
        )
        let command = Self.command(
            tmuxPath: tmuxPath,
            sessionName: selection.name,
            socketName: selection.socketName,
            expectedIdentity: expectedIdentity,
            platform: Self.platform(for: host)
        )
        let routedRunner = runner
        let result = await commandLease.runCommand(using: connection) { _ in
            routedRunner(host, sshConnectionArguments, command)
        }
        guard result.status == 0 else {
            if result.status == 1,
               Self.isConfirmedAbsence(result.stdout) {
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
            throw TmuxSessionKillError.commandFailed(
                host: host.displayName,
                session: selection.name,
                status: result.status
            )
        }
        guard !Self.hasIdentityMismatch(result.stdout) else {
            throw TmuxSessionKillError.sessionChanged(
                host: host.displayName,
                session: selection.name
            )
        }
    }

    func killReviewed(
        _ selection: WorkspaceTmuxSessionSelection,
        expectedIdentity: TmuxSessionIdentity,
        expectedRouteIdentity: String?,
        on host: CommandHost
    ) async throws {
        try await commandLease.withConnection(on: host) { connection in
            guard expectedRouteIdentity == connection?.routeIdentity else {
                throw TmuxSessionKillError.hostChanged(
                    session: selection.name
                )
            }
            try await killWithArguments(
                selection,
                expectedIdentity: expectedIdentity,
                on: host,
                sshConnectionArguments: connection?.arguments,
                connection: connection
            )
        }
    }

    func sessionIdentity(
        _ selection: WorkspaceTmuxSessionSelection,
        on host: CommandHost,
        sshConnectionArguments: [String]? = nil
    ) async throws -> TmuxSessionIdentity {
        try await withConnection(sshConnectionArguments, on: host) {
            sshConnectionArguments, connection in
            try await sessionIdentityWithArguments(
                selection,
                on: host,
                sshConnectionArguments: sshConnectionArguments,
                connection: connection
            )
        }
    }

    private func sessionIdentityWithArguments(
        _ selection: WorkspaceTmuxSessionSelection,
        on host: CommandHost,
        sshConnectionArguments: [String]?,
        connection: KwtSSHConnection?
    ) async throws -> TmuxSessionIdentity {
        let tmuxPath = try await resolveTmuxPath(
            on: host,
            sshConnectionArguments: sshConnectionArguments,
            connection: connection
        )
        let platform = Self.platform(for: host)
        let probeCommand = Self.sessionProbeCommand(
            tmuxPath: tmuxPath,
            sessionName: selection.name,
            socketName: selection.socketName,
            platform: platform
        )
        let routedRunner = runner
        let probe = await commandLease.runCommand(using: connection) { _ in
            routedRunner(host, sshConnectionArguments, probeCommand)
        }
        guard probe.status == 0 else {
            if probe.status == 1,
               Self.isConfirmedAbsence(probe.stdout) {
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
            throw TmuxSessionKillError.identityCommandFailed(
                host: host.displayName,
                session: selection.name,
                status: probe.status
            )
        }
        let identityCommand = Self.identityCommand(
            tmuxPath: tmuxPath,
            sessionName: selection.name,
            socketName: selection.socketName,
            platform: platform
        )
        let result = await commandLease.runCommand(using: connection) { _ in
            routedRunner(host, sshConnectionArguments, identityCommand)
        }
        guard result.status == 0 else {
            throw TmuxSessionKillError.identityCommandFailed(
                host: host.displayName,
                session: selection.name,
                status: result.status
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

    func reviewedIdentity(
        _ selection: WorkspaceTmuxSessionSelection,
        knownIdentity: TmuxSessionIdentity? = nil,
        on host: CommandHost
    ) async throws -> ReviewedTmuxSessionIdentity {
        try await commandLease.withConnection(on: host) { connection in
            let identity = if let knownIdentity {
                knownIdentity
            } else {
                try await sessionIdentityWithArguments(
                    selection,
                    on: host,
                    sshConnectionArguments: connection?.arguments,
                    connection: connection
                )
            }
            return ReviewedTmuxSessionIdentity(
                identity: identity,
                routeIdentity: connection?.routeIdentity
            )
        }
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
            expectedIdentity.formatCondition,
            "kill-session -t \(shellQuotedCommandArgument(target))",
            "display-message -p "
                + shellQuotedCommandArgument(identityMismatchMarker),
        ])
        if platform == .windows {
            arguments[arguments.count - 2] =
                "kill-session -t \(expectedIdentity.sessionID)"
            arguments[arguments.count - 1] =
                "display-message -p \(identityMismatchMarker)"
            return powerShellCommand(
                arguments,
                captureStandardError: true,
                frameOutput: true
            )
        }
        return framedPOSIXCommand(arguments)
    }

    private static func identityCommand(
        tmuxPath: String,
        sessionName: String,
        socketName: String?,
        platform: SSHHostInfo.Platform
    ) -> String {
        var arguments = [tmuxPath]
        if let socketName {
            arguments.append(contentsOf: ["-L", socketName])
        }
        arguments.append(contentsOf: [
            "display-message",
            "-p",
            "-t",
            "=\(sessionName):",
            identityMarker + "#{pid}\t#{session_id}\t#{session_created}",
        ])
        if platform == .windows {
            return powerShellCommand(arguments)
        }
        return arguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
    }

    private static func sessionProbeCommand(
        tmuxPath: String,
        sessionName: String,
        socketName: String?,
        platform: SSHHostInfo.Platform
    ) -> String {
        var arguments = [tmuxPath]
        if let socketName {
            arguments.append(contentsOf: ["-L", socketName])
        }
        arguments.append(contentsOf: [
            "has-session",
            "-t",
            "=\(sessionName):",
        ])
        if platform == .windows {
            return powerShellCommand(
                arguments,
                captureStandardError: true,
                frameOutput: true
            )
        }
        return framedPOSIXCommand(arguments)
    }

    static func isConfirmedAbsence(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { rawLine in
            guard rawLine.hasPrefix(diagnosticMarker) else { return false }
            let line = rawLine.dropFirst(diagnosticMarker.count)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return line.hasPrefix("can't find session:")
                || line.hasPrefix("no server running on ")
                || line ==
                "failed to connect to server: no such file or directory"
                || (line.hasPrefix("error connecting to ")
                    && line.hasSuffix("(no such file or directory)"))
        }
    }

    private static func hasIdentityMismatch(_ output: String) -> Bool {
        let expected = diagnosticMarker + identityMismatchMarker
        return output.split(whereSeparator: \.isNewline).contains {
            $0 == expected
        }
    }

    private static func framedPOSIXCommand(
        _ arguments: [String]
    ) -> String {
        let invocation = arguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        let marker = shellQuotedCommandArgument(diagnosticMarker)
        return """
        GHOSTHUB_TMUX_OUTPUT=$(\(invocation) 2>&1)
        GHOSTHUB_TMUX_STATUS=$?
        if [ -n "$GHOSTHUB_TMUX_OUTPUT" ]; then
            printf '%s\\n' "$GHOSTHUB_TMUX_OUTPUT" |
                while IFS= read -r GHOSTHUB_TMUX_LINE; do
                    printf '%s%s\\n' \(marker) "$GHOSTHUB_TMUX_LINE"
                done
        fi
        exit "$GHOSTHUB_TMUX_STATUS"
        """
    }

    private static func powerShellCommand(
        _ arguments: [String],
        captureStandardError: Bool = false,
        frameOutput: Bool = false
    ) -> String {
        let invocation = "& "
            + arguments.map(powerShellEncodedArgument).joined(separator: " ")
            + (captureStandardError ? " 2>&1" : "")
        let body: String
        if frameOutput {
            body = """
            $GhosthubTmuxOutput = \(invocation)
            $GhosthubTmuxStatus = $LASTEXITCODE
            foreach ($GhosthubTmuxLine in $GhosthubTmuxOutput) {
                [Console]::Out.WriteLine(
                    \(powerShellEncodedArgument(diagnosticMarker))
                        + [string]$GhosthubTmuxLine
                )
            }
            exit $GhosthubTmuxStatus
            """
        } else {
            body = """
            \(invocation)
            exit $LASTEXITCODE
            """
        }
        return """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        \(body)
        """
    }

    private static func platform(
        for host: CommandHost
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
