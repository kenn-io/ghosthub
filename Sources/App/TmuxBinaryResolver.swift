import GhosthubTransport
import Foundation
import GhosthubTmux
import GhosthubWorkspace

enum TmuxBinaryError: Error, Equatable, LocalizedError, Sendable {
    case notFound(shell: String)
    case shellFailed(status: Int32)
    case sshConnectionFailed(
        host: String,
        classification: SSHConnectionFailure.Classification
    )
    case probeTimedOut(shell: String)
    case probeCancelled(shell: String)
    case probeOutputExceeded(shell: String)
    case sessionContextUnavailable
    case unsupportedVersion(found: String, minimum: String)
    case ownershipPersistenceFailed

    var errorDescription: String? {
        switch self {
        case let .notFound(shell):
            return "tmux was not found on the PATH of your login shell"
                + " (\(shell)). Install tmux (e.g. `brew install tmux`)"
                + " and reopen the worktree terminal."
        case let .shellFailed(status):
            return "The login shell exited with status \(status) while"
                + " locating tmux. Check your shell startup files."
        case let .sshConnectionFailed(host, classification):
            return "\(classification.diagnostic.summary) Host: \(host). "
                + classification.diagnostic.recoverySuggestion
        case let .probeTimedOut(shell):
            return "Timed out while locating tmux through \(shell). Check"
                + " for commands that block in your shell startup files."
        case let .probeCancelled(shell):
            return "Stopped locating tmux through \(shell) because the"
                + " terminal was closed. Reopen it to retry."
        case let .probeOutputExceeded(shell):
            return "The tmux lookup through \(shell) produced too much"
                + " output. Check noisy shell startup files and retry."
        case .sessionContextUnavailable:
            return "The worktree is no longer available for terminal setup."
        case let .unsupportedVersion(found, minimum):
            return "Ghosthub requires tmux \(minimum) or newer, but found"
                + " \(found.isEmpty ? "an unrecognized version" : found)."
        case .ownershipPersistenceFailed:
            return "Ghosthub could not save the tmux session ownership"
                + " identity. Reopen the worktree terminal to retry."
        }
    }
}

struct DiscoveredTmuxSession: Equatable, Sendable {
    var name: String
    var windowCount: Int
    var serverPID: String?
    var sessionID: String?
    var createdAt: String?
    var activeWindowSize: TmuxGridSize?
    var previewClientSize: TmuxGridSize?
    var managed: Bool

    init(
        name: String,
        windowCount: Int,
        serverPID: String? = nil,
        sessionID: String? = nil,
        createdAt: String?,
        activeWindowSize: TmuxGridSize? = nil,
        previewClientSize: TmuxGridSize? = nil,
        managed: Bool
    ) {
        self.name = name
        self.windowCount = windowCount
        self.serverPID = serverPID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.activeWindowSize = activeWindowSize
        self.previewClientSize = previewClientSize
        self.managed = managed
    }
}

struct ResolvedTmuxBinary: Equatable, Sendable {
    var path: String
    var version: String
}

/// Resolves the tmux binary through the user's login shell, because a
/// launchd-launched GUI app does not inherit Homebrew or user-bin PATH
/// entries. Reads the passwd shell (not $SHELL, which may be absent).
struct TmuxBinaryResolver: Sendable {
    private static let timedOutStatus = AccountCommandRunner.timedOutStatus
    private static let outputExceededStatus =
        AccountCommandRunner.outputExceededStatus
    private static let cancelledStatus = AccountCommandRunner.cancelledStatus
    typealias ProcessRunner = @Sendable (_ shell: String, _ command: String)
        -> (status: Int32, stdout: String)
    typealias RemoteProcessRunner = @Sendable (
        _ host: SSHHostInfo,
        _ sshConnectionArguments: [String],
        _ command: String
    ) -> (status: Int32, stdout: String, stderr: String)

    private let processRunner: ProcessRunner
    private let remoteProcessRunner: RemoteProcessRunner
    private let loginShellProvider: @Sendable () -> String
    private let commandLease: KwtSSHCommandLease

    init(
        processRunner: ProcessRunner? = nil,
        remoteProcessRunner: RemoteProcessRunner? = nil,
        processTimeout: TimeInterval = 15,
        loginShellProvider: @escaping @Sendable () -> String =
            AccountCommandRunner.loginShell,
        commandLease: KwtSSHCommandLease? = nil
    ) {
        self.commandLease = commandLease ?? .unlessInjected(
            remoteProcessRunner != nil
        )
        self.processRunner = processRunner ?? { shell, command in
            AccountCommandRunner.runLoginShell(
                shell: shell, command: command, timeout: processTimeout
            )
        }
        self.remoteProcessRunner = remoteProcessRunner ?? {
            host, sshConnectionArguments, command in
            let result = AccountCommandRunner(
                loginShellProvider: loginShellProvider
            ).runRemoteLoginShell(
                host: host,
                connectionArguments: sshConnectionArguments,
                command: command,
                timeout: processTimeout
            )
            return (result.status, result.stdout, result.stderr)
        }
        self.loginShellProvider = loginShellProvider
    }

    func resolveTmuxPath() -> Result<String, TmuxBinaryError> {
        resolveTmuxBinary().map(\.path)
    }

    func resolveTmuxBinary() -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
        let shell = loginShellProvider()
        let result = processRunner(shell, Self.probeCommand)
        return Self.parseProbe(result, shell: shell, platform: .posix)
    }

    /// Resolves the remote tmux path through one borrowed kwt lease.
    func resolveTmuxPath(
        on host: SSHHostInfo
    ) async -> Result<String, TmuxBinaryError> {
        await borrowing(host) { arguments in
            resolveTmuxPath(on: host, sshConnectionArguments: arguments)
        }
    }

    private func borrowing<Value: Sendable>(
        _ host: SSHHostInfo,
        operation: @escaping @Sendable ([String]) -> Result<Value, TmuxBinaryError>
    ) async -> Result<Value, TmuxBinaryError> {
        do {
            return try await commandLease.withConnection(on: .ssh(host)) {
                connection in
                let result = await BlockingTask.run {
                    operation(connection?.arguments ?? [])
                }
                if case let .failure(.sshConnectionFailed(_, classification)) =
                    result, classification.connectionUnusable {
                    await connection?.invalidate()
                }
                return result
            }
        } catch {
            return .failure(.sshConnectionFailed(
                host: host.displayName,
                classification: SSHConnectionFailure.classify(leaseError: error)
            ))
        }
    }

    func resolveTmuxPath(
        on host: SSHHostInfo,
        sshConnectionArguments: [String]
    ) -> Result<String, TmuxBinaryError> {
        resolveTmuxBinary(
            on: host,
            sshConnectionArguments: sshConnectionArguments
        ).map(\.path)
    }

    func resolveTmuxBinary(
        on host: SSHHostInfo,
        sshConnectionArguments: [String]
    ) -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
        let result = remoteProcessRunner(
            host,
            sshConnectionArguments,
            Self.probeCommand(for: host.platform)
        )
        if result.status == 255 {
            return .failure(.sshConnectionFailed(
                host: host.displayName,
                classification: SSHConnectionFailure.classify(
                    status: result.status,
                    output: result.stderr
                )
            ))
        }
        return Self.parseProbe(
            (status: result.status, stdout: result.stdout),
            shell: host.displayName,
            platform: host.platform
        )
    }

    func discoverSessions() -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        let shell = loginShellProvider()
        return Self.parseDiscovery(
            processRunner(shell, Self.discoveryCommand),
            shell: shell,
            platform: .posix
        )
    }

    func discoverSessions(
        on host: SSHHostInfo
    ) async -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        await borrowing(host) { arguments in
            discoverSessions(on: host, sshConnectionArguments: arguments)
        }
    }

    func discoverSessions(
        on host: SSHHostInfo,
        sshConnectionArguments: [String]
    ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        let result = remoteProcessRunner(
            host,
            sshConnectionArguments,
            Self.discoveryCommand(for: host.platform)
        )
        if result.status == 255 {
            return .failure(.sshConnectionFailed(
                host: host.displayName,
                classification: SSHConnectionFailure.classify(
                    status: result.status,
                    output: result.stderr
                )
            ))
        }
        return Self.parseDiscovery(
            (status: result.status, stdout: result.stdout),
            shell: host.displayName,
            platform: host.platform
        )
    }

    func sessionExists(
        name: String,
        socketName: String?,
        on host: SSHHostInfo
    ) async -> Result<Bool, TmuxBinaryError> {
        await borrowing(host) { arguments in
            sessionExists(
                name: name,
                socketName: socketName,
                on: host,
                sshConnectionArguments: arguments
            )
        }
    }

    func sessionExists(
        name: String,
        socketName: String?,
        on host: SSHHostInfo,
        sshConnectionArguments: [String]
    ) -> Result<Bool, TmuxBinaryError> {
        let result = remoteProcessRunner(
            host,
            sshConnectionArguments,
            Self.sessionProbeCommand(
                name: name,
                socketName: socketName,
                platform: host.platform
            )
        )
        if result.status == 255 {
            return .failure(.sshConnectionFailed(
                host: host.displayName,
                classification: SSHConnectionFailure.classify(
                    status: result.status,
                    output: result.stderr
                )
            ))
        }
        guard result.status == 0 else {
            switch result.status {
            case Self.timedOutStatus:
                return .failure(.probeTimedOut(shell: host.displayName))
            case Self.cancelledStatus:
                return .failure(.probeCancelled(shell: host.displayName))
            case Self.outputExceededStatus:
                return .failure(.probeOutputExceeded(shell: host.displayName))
            default:
                return .failure(.shellFailed(status: result.status))
            }
        }
        switch Self.parseProbe(
            (status: result.status, stdout: result.stdout),
            shell: host.displayName,
            platform: host.platform
        ) {
        case let .failure(error):
            return .failure(error)
        case .success:
            break
        }

        let outcomes = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Bool? in
                switch line {
                case Substring(Self.sessionPresentMarker): true
                case Substring(Self.sessionAbsentMarker): false
                default: nil
                }
            }
        guard outcomes.count == 1, let exists = outcomes.first else {
            return .failure(.shellFailed(status: result.status))
        }
        return .success(exists)
    }

    private static let probeCommand =
        "ghosthub_tmux_path=$(command -v tmux) || exit $?; "
            + "printf '%s\\n' \"$ghosthub_tmux_path\"; "
            + "\"$ghosthub_tmux_path\" -V || exit $?"

    private static let discoveryPrefix = "GHOSTHUB_TMUX_SESSION"
    private static let sessionPresentMarker =
        "GHOSTHUB_TMUX_SESSION_PRESENT"
    private static let sessionAbsentMarker =
        "GHOSTHUB_TMUX_SESSION_ABSENT"
    private static let discoveryFormat = discoveryPrefix
        + "\t#{session_windows}\t#{pid}\t#{session_id}\t#{session_created}"
        + "\t#{window_width}\t#{window_height}"
        + "\t#{status}"
        + "\t#{@ghosthub_owner}\t#{session_name}"
    private static let discoveryCommand = probeCommand
        + "; ghosthub_tmux_output=$("
        + "\"$ghosthub_tmux_path\" list-sessions -F "
        + shellQuotedCommandArgument(discoveryFormat)
        + " 2>&1); ghosthub_tmux_status=$?; "
        + "if [ \"$ghosthub_tmux_status\" -eq 0 ]; then "
        + "printf '%s\\n' \"$ghosthub_tmux_output\"; else "
        + "printf '%s\\n' \"$ghosthub_tmux_output\" >&2; "
        + "case \"$ghosthub_tmux_output\" in "
        + "*\"no server running on \"*|"
        + "*\"failed to connect to server: No such file or directory\"*|"
        + "*\"error connecting to \"*\" (No such file or directory)\"*) "
        + "exit 0 ;; *) exit \"$ghosthub_tmux_status\" ;; esac; fi"

    private static func probeCommand(
        for platform: SSHHostInfo.Platform
    ) -> String {
        switch platform {
        case .posix:
            probeCommand
        case .windows:
            windowsProbePrelude + """

            Write-Output $ghosthubMux
            & $ghosthubMux '-V'
            exit $LASTEXITCODE
            """
        }
    }

    private static func discoveryCommand(
        for platform: SSHHostInfo.Platform
    ) -> String {
        switch platform {
        case .posix:
            discoveryCommand
        case .windows:
            windowsProbePrelude + """

            Write-Output $ghosthubMux
            & $ghosthubMux '-V'
            if ($LASTEXITCODE -ne 0) {
                exit $LASTEXITCODE
            }
            $ghosthubMuxOutput = (& $ghosthubMux 'list-sessions' '-F' \(
                powerShellEncodedArgument(discoveryFormat)
            ) 2>&1 | Out-String)
            $ghosthubMuxStatus = $LASTEXITCODE
            if ($ghosthubMuxStatus -eq 0) {
                Write-Output $ghosthubMuxOutput
                exit 0
            }
            [Console]::Error.Write($ghosthubMuxOutput)
            if ($ghosthubMuxOutput -match 'no server running on ' -or
                $ghosthubMuxOutput -match 'failed to connect to server: No such file or directory') {
                exit 0
            }
            exit $ghosthubMuxStatus
            """
        }
    }

    private static func sessionProbeCommand(
        name: String,
        socketName: String?,
        platform: SSHHostInfo.Platform
    ) -> String {
        switch platform {
        case .posix:
            var arguments = [String]()
            if let socketName {
                arguments.append(contentsOf: ["-L", socketName])
            }
            arguments.append(contentsOf: ["has-session", "-t", "=\(name)"])
            let command = arguments
                .map(shellQuotedCommandArgument)
                .joined(separator: " ")
            return probeCommand
                + "; ghosthub_probe_error=$("
                + "\"$ghosthub_tmux_path\" \(command) 2>&1); "
                + "ghosthub_probe_status=$?; "
                + "if [ \"$ghosthub_probe_status\" -eq 0 ]; then "
                + "printf '\(sessionPresentMarker)\\n'; "
                + "else printf '%s\\n' \"$ghosthub_probe_error\" >&2; "
                + "case \"$ghosthub_probe_error\" in "
                + "*\"can't find session:\"*|*\"no server running on \"*|"
                + "*\"failed to connect to server: No such file or directory\"*|"
                + "*\"error connecting to \"*\" (No such file or directory)\"*) "
                + "printf '\(sessionAbsentMarker)\\n' ;; "
                + "*) exit \"$ghosthub_probe_status\" ;; esac; fi"
        case .windows:
            var arguments = [String]()
            if let socketName {
                arguments.append(contentsOf: ["-L", socketName])
            }
            arguments.append(contentsOf: ["has-session", "-t", "=\(name)"])
            let command = arguments
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
            return windowsProbePrelude + """

            Write-Output $ghosthubMux
            & $ghosthubMux '-V'
            if ($LASTEXITCODE -ne 0) {
                exit $LASTEXITCODE
            }
            $ghosthubProbeError = (& $ghosthubMux \(command) 2>&1 | Out-String)
            $ghosthubProbeStatus = $LASTEXITCODE
            if ($ghosthubProbeStatus -eq 0) {
                Write-Output '\(sessionPresentMarker)'
                exit 0
            }
            [Console]::Error.Write($ghosthubProbeError)
            if ($ghosthubProbeError -match "can't find session:" -or
                $ghosthubProbeError -match 'no server running on ' -or
                $ghosthubProbeError -match 'failed to connect to server: No such file or directory') {
                Write-Output '\(sessionAbsentMarker)'
                exit 0
            }
            exit $ghosthubProbeStatus
            """
        }
    }

    private static let windowsProbePrelude = """
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Console]::OutputEncoding
    $ghosthubMux = (Get-Command tmux.exe -CommandType Application -ErrorAction Stop).Source
    """

    private static func parseProbe(
        _ result: (status: Int32, stdout: String),
        shell: String,
        platform: SSHHostInfo.Platform
    ) -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
        guard result.status == 0 else {
            if result.status == timedOutStatus {
                return .failure(.probeTimedOut(shell: shell))
            }
            if result.status == cancelledStatus {
                return .failure(.probeCancelled(shell: shell))
            }
            if result.status == outputExceededStatus {
                return .failure(.probeOutputExceeded(shell: shell))
            }
            if result.status == 1 || result.status == 127 {
                return .failure(.notFound(shell: shell))
            }
            return .failure(.shellFailed(status: result.status))
        }
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard let pathIndex = lines.indices.first(where: {
            isAbsoluteExecutablePath(lines[$0])
                && lines.indices.contains($0 + 1)
                && lines[$0 + 1].hasPrefix("tmux ")
        })
        else {
            return .failure(.notFound(shell: shell))
        }
        let path = lines[pathIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = lines[pathIndex + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSupported(version, platform: platform) else {
            return .failure(.unsupportedVersion(
                found: version,
                minimum: minimumVersion(for: platform)
            ))
        }
        return .success(ResolvedTmuxBinary(path: path, version: version))
    }

    private static func isAbsoluteExecutablePath(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("\\\\") {
            return true
        }
        guard value.count >= 3 else { return false }
        let characters = Array(value)
        return characters[0].isLetter
            && characters[1] == ":"
            && (characters[2] == "\\" || characters[2] == "/")
    }

    private static func parseDiscovery(
        _ result: (status: Int32, stdout: String),
        shell: String,
        platform: SSHHostInfo.Platform
    ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        if result.status != 0 {
            switch result.status {
            case timedOutStatus, cancelledStatus, outputExceededStatus:
                if case let .failure(error) = parseProbe(
                    result,
                    shell: shell,
                    platform: platform
                ) {
                    return .failure(error)
                }
            default:
                if case .success = parseProbe(
                    (status: 0, stdout: result.stdout),
                    shell: shell,
                    platform: platform
                ) {
                    return .failure(.shellFailed(status: result.status))
                }
            }
        }
        switch parseProbe(result, shell: shell, platform: platform) {
        case let .failure(error):
            return .failure(error)
        case .success:
            break
        }
        let prefix = discoveryPrefix + "\t"
        let sessions = result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> DiscoveredTmuxSession? in
                let line = String(rawLine)
                guard line.hasPrefix(prefix) else { return nil }
                let fields = line.split(
                    separator: "\t",
                    maxSplits: 9,
                    omittingEmptySubsequences: false
                )
                guard fields.count == 10,
                      let windowCount = Int(fields[1]),
                      windowCount >= 0
                else { return nil }
                let activeWindowSize: TmuxGridSize? = if let columns = Int(fields[5]),
                                                         let rows = Int(fields[6]),
                                                         columns > 0, rows > 0 {
                    TmuxGridSize(columns: columns, rows: rows)
                } else {
                    nil
                }
                let statusRows: Int? = switch fields[7] {
                case "off": 0
                case "on": 1
                default: Int(fields[7]).flatMap { $0 >= 0 ? $0 : nil }
                }
                let previewClientSize: TmuxGridSize? = activeWindowSize
                    .flatMap { size in
                        guard let statusRows else { return nil }
                        let (rows, overflow) = size.rows.addingReportingOverflow(
                            statusRows
                        )
                        guard !overflow, rows > 0 else { return nil }
                        return TmuxGridSize(columns: size.columns, rows: rows)
                    }
                return DiscoveredTmuxSession(
                    name: String(fields[9]),
                    windowCount: windowCount,
                    serverPID: fields[2].isEmpty ? nil : String(fields[2]),
                    sessionID: fields[3].isEmpty ? nil : String(fields[3]),
                    createdAt: fields[4].isEmpty ? nil : String(fields[4]),
                    activeWindowSize: activeWindowSize,
                    previewClientSize: previewClientSize,
                    managed: !fields[8].isEmpty
                )
            }
        return .success(sessions)
    }

    private static func isSupported(
        _ output: String,
        platform: SSHHostInfo.Platform
    ) -> Bool {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "tmux" else { return false }
        let components = fields[1].split(separator: ".", maxSplits: 1)
        guard components.count == 2,
              let major = Int(components[0]) else { return false }
        let minorDigits = components[1].prefix(while: \.isNumber)
        guard let minor = Int(minorDigits) else { return false }
        let minimumMinor = 2
        return major > 3 || (major == 3 && minor >= minimumMinor)
    }

    private static func minimumVersion(
        for platform: SSHHostInfo.Platform
    ) -> String {
        "3.2"
    }

}
