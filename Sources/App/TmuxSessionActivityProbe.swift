import Foundation
import GhosthubTransport
import GhosthubTmux
import GhosthubUI

enum TmuxSessionActivityProbeResult: Equatable, Sendable {
    case sample(
        paneID: String,
        dimensions: String,
        fingerprint: String,
        windowCount: Int? = nil
    )
    case ended
    case unavailable
}

struct TmuxSessionActivityProbe: Sendable {
    typealias PathResolver = @Sendable (CommandHost)
        -> Result<String, TmuxBinaryError>
    typealias Runner = @Sendable (CommandHost, String)
        -> (status: Int32, stdout: String)

    private static let identityMarker =
        "GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t"
    private static let checksumMarker =
        "GHOSTHUB_TMUX_ACTIVITY_CHECKSUM\t"
    private static let endedMarker =
        "GHOSTHUB_TMUX_ACTIVITY_ENDED"
    private static let mismatchMarker =
        "GHOSTHUB_TMUX_ACTIVITY_MISMATCH"
    private static let supportMarker =
        "GHOSTHUB_TMUX_ACTIVITY_SUPPORTED"

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
        let cache = TmuxSessionActivityPathCache(
            resolve: { host, connectionArguments in
                if let pathResolver {
                    return pathResolver(host)
                }
                return Self.resolveTmuxPath(
                    on: host,
                    sshConnectionArguments: connectionArguments
                )
            }
        )
        self.pathResolver = { host, connectionArguments in
            cache.resolve(on: host, sshConnectionArguments: connectionArguments)
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
                    timeout: 10
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
                    timeout: 10
                )
            }
        }
    }

    func sample(
        _ selection: WorkspaceTmuxSessionSelection,
        expectedIdentity: TmuxSessionIdentity,
        on host: CommandHost
    ) async -> TmuxSessionActivityProbeResult {
        guard TmuxSessionKiller.isNumericIdentity(expectedIdentity.serverPID),
              TmuxSessionKiller.isSessionID(expectedIdentity.sessionID),
              TmuxSessionKiller.isSessionCreatedAt(expectedIdentity.createdAt)
        else {
            return .unavailable
        }
        let pathResolver = pathResolver
        let runner = runner
        do {
            return try await commandLease.withConnection(on: host) {
                connection in
                let connectionArguments = connection?.arguments
                guard !Task.isCancelled else { return .unavailable }
                let pathResult = await BlockingTask.run(priority: .utility) {
                    pathResolver(host, connectionArguments)
                }
                if case let .failure(.sshConnectionFailed(
                    _, classification
                )) = pathResult,
                    classification.connectionUnusable {
                    await connection?.invalidate()
                }
                guard let tmuxPath = try? pathResult.get(),
                      !Task.isCancelled
                else {
                    return .unavailable
                }
                let command = Self.command(
                    tmuxPath: tmuxPath,
                    selection: selection,
                    expectedIdentity: expectedIdentity,
                    platform: Self.platform(for: host)
                )
                let result = await commandLease.runCommand(
                    using: connection
                ) { _ in
                    runner(host, connectionArguments, command)
                }
                guard result.status == 0 else { return .unavailable }
                return Self.parse(
                    result.stdout,
                    expectedIdentity: expectedIdentity
                )
            }
        } catch {
            return .unavailable
        }
    }

    static func command(
        tmuxPath: String,
        selection: WorkspaceTmuxSessionSelection,
        expectedIdentity: TmuxSessionIdentity,
        platform: SSHHostInfo.Platform = .posix
    ) -> String {
        if platform == .windows {
            return windowsCommand(
                tmuxPath: tmuxPath,
                selection: selection,
                expectedIdentity: expectedIdentity
            )
        }
        var baseArguments = [tmuxPath]
        if let socketName = selection.socketName {
            baseArguments.append(contentsOf: ["-L", socketName])
        }
        let base = baseArguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        let target = shellQuotedCommandArgument("=\(selection.name):")
        let format = shellQuotedCommandArgument(
            identityMarker
                + "#{pid}\t#{session_id}\t#{session_created}\t#{pane_id}"
                + "\t#{pane_width}x#{pane_height}\t#{session_windows}"
        )
        let identity = base
            + " display-message -p -t " + target + " " + format
        let predicate = Self.identityPredicate(expectedIdentity)
        let historySize = base
            + " display-message -p -t \"$ghosthub_activity_pane\" "
            + shellQuotedCommandArgument(
                "#{?\(predicate),#{history_size},\(mismatchMarker)}"
            )
        let checkedIdentity = """
        ghosthub_activity_identity=$(\(identity) 2>&1)
        ghosthub_activity_status=$?
        if [ "$ghosthub_activity_status" -ne 0 ]; then
            case "$ghosthub_activity_identity" in
                *"can't find session:"*|*"no server running on "*)
                    printf '\(endedMarker)\n'
                    exit 0
                    ;;
                *"error connecting to "*"(No such file or directory)"*)
                    printf '\(endedMarker)\n'
                    exit 0
                    ;;
                *"failed to connect to server: No such file or directory"*)
                    printf '\(endedMarker)\n'
                    exit 0
                    ;;
            esac
            printf '%s\n' "$ghosthub_activity_identity" >&2
            exit "$ghosthub_activity_status"
        fi
        printf '%s\n' "$ghosthub_activity_identity"
        """
        let capture = base
            + " if-shell -F -t \"$ghosthub_activity_pane\" "
            + shellQuotedCommandArgument(predicate)
            + " \"capture-pane -p -t $ghosthub_activity_pane -S -160 -E -1\" "
            + shellQuotedCommandArgument(
                "display-message -p \(mismatchMarker)"
            )
        let expectedPrefix = shellQuotedCommandArgument(
            Self.expectedIdentityPrefix(expectedIdentity)
        )
        return """
        \(checkedIdentity)
        ghosthub_activity_expected=\(expectedPrefix)
        case "$ghosthub_activity_identity" in
            "$ghosthub_activity_expected"*) ;;
            *)
                printf '\(endedMarker)\n'
                exit 0
                ;;
        esac
        ghosthub_activity_pane=${ghosthub_activity_identity#"$ghosthub_activity_expected"}
        ghosthub_activity_pane=${ghosthub_activity_pane%%\(tabLiteral)*}
        case "$ghosthub_activity_pane" in
            %*[!0-9]*|%) exit 65 ;;
            %[0-9]*) ;;
            *) exit 65 ;;
        esac
        ghosthub_activity_history_size=$(\(historySize)) || exit $?
        case "$ghosthub_activity_history_size" in
            '\(mismatchMarker)')
                printf '\(endedMarker)\n'
                exit 0
                ;;
            ''|*[!0-9]*) exit 65 ;;
        esac
        if [ "$ghosthub_activity_history_size" -eq 0 ]; then
            ghosthub_activity_capture=
        else
            ghosthub_activity_capture=$(
                \(capture) || exit $?
                printf '%s' 'GHOSTHUB_TMUX_ACTIVITY_CAPTURE_END'
            ) || exit $?
            ghosthub_activity_capture=${ghosthub_activity_capture%GHOSTHUB_TMUX_ACTIVITY_CAPTURE_END}
        fi
        ghosthub_activity_checksum=$(printf '%s' "$ghosthub_activity_capture" | cksum) || exit $?
        set -- $ghosthub_activity_checksum
        [ "$#" -ge 2 ] || exit 65
        printf '\(checksumMarker)%s\t%s\t%s\n' \
            "$1" "$2" "$ghosthub_activity_history_size"
        \(checkedIdentity)
        """
    }

    private static let tabLiteral = "\t"

    private static func identityPredicate(
        _ identity: TmuxSessionIdentity
    ) -> String {
        "#{&&:#{==:#{pid},\(identity.serverPID)},"
            + "#{&&:#{==:#{session_id},\(identity.sessionID)},"
            + "#{==:#{session_created},\(identity.createdAt)}}}"
    }

    private static func expectedIdentityPrefix(
        _ identity: TmuxSessionIdentity
    ) -> String {
        identityMarker
            + identity.serverPID + "\t"
            + identity.sessionID + "\t"
            + identity.createdAt + "\t"
    }

    private static func windowsCommand(
        tmuxPath: String,
        selection: WorkspaceTmuxSessionSelection,
        expectedIdentity: TmuxSessionIdentity
    ) -> String {
        var baseArguments: [String] = []
        if let socketName = selection.socketName {
            baseArguments.append(contentsOf: ["-L", socketName])
        }
        let target = "=\(selection.name):"
        let format = identityMarker
            + "#{pid}\t#{session_id}\t#{session_created}\t#{pane_id}"
            + "\t#{pane_width}x#{pane_height}\t#{session_windows}"
        let identity = powerShellInvocation(
            tmuxPath: tmuxPath,
            arguments: baseArguments + [
                "display-message", "-p", "-t", target, format,
            ]
        )
        let version = powerShellInvocation(
            tmuxPath: tmuxPath,
            arguments: ["-V"]
        )
        let predicate = identityPredicate(expectedIdentity)
        let displayPrefix = ([tmuxPath] + baseArguments + [
            "display-message", "-p",
        ]).map(powerShellEncodedArgument).joined(separator: " ")
        let formatProbe = "& " + displayPrefix + " "
            + powerShellEncodedArgument(
                "#{?#{&&:#{==:1,1},#{==:2,2}},\(supportMarker),unsupported}"
            )
        let ifShellPrefix = ([tmuxPath] + baseArguments + ["if-shell", "-F"])
            .map(powerShellEncodedArgument).joined(separator: " ")
        let ifShellProbe = "& " + ifShellPrefix + " "
            + powerShellEncodedArgument("1") + " "
            + powerShellEncodedArgument("display-message -p \(supportMarker)")
            + " "
            + powerShellEncodedArgument("display-message -p unsupported")
        let historySize = "& " + displayPrefix + " "
            + powerShellEncodedArgument("-t") + " $ghosthubActivityPane "
            + powerShellEncodedArgument(
                "#{?\(predicate),#{history_size},\(mismatchMarker)}"
            )
        let checkedIdentity = """
        $ghosthubActivityIdentity = (\(identity) 2>&1 | Out-String).TrimEnd()
        $ghosthubActivityStatus = $LASTEXITCODE
        if ($ghosthubActivityStatus -ne 0) {
            if ($ghosthubActivityIdentity -match "(?i)can't find session:|no server running on |error connecting to .*\\(No such file or directory\\)|failed to connect to server: No such file or directory") {
                Write-Output '\(endedMarker)'
                exit 0
            }
            [Console]::Error.WriteLine($ghosthubActivityIdentity)
            exit $ghosthubActivityStatus
        }
        Write-Output $ghosthubActivityIdentity
        """
        let capture = "& " + ifShellPrefix + " "
            + powerShellEncodedArgument("-t") + " $ghosthubActivityPane "
            + powerShellEncodedArgument(predicate)
            + " (\"capture-pane -p -t \" + $ghosthubActivityPane"
            + " + \" -S -160 -E -1\") "
            + powerShellEncodedArgument(
                "display-message -p \(mismatchMarker)"
            )
        return """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        $ghosthubActivityVersionOutput = (\(version) 2>&1 | Out-String).Trim()
        if (($LASTEXITCODE -ne 0) -or ($ghosthubActivityVersionOutput -notmatch '^tmux\\s+(\\d+)\\.(\\d+)(?:\\.(\\d+))?')) {
            exit 69
        }
        $ghosthubActivityPatch = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
        $ghosthubActivityVersion = [Version]::new(
            [int]$Matches[1],
            [int]$Matches[2],
            $ghosthubActivityPatch
        )
        if ($ghosthubActivityVersion -lt [Version]'3.3.4') { exit 69 }
        \(checkedIdentity)
        $ghosthubActivityExpected = \(
            powerShellEncodedArgument(
                expectedIdentityPrefix(expectedIdentity)
            )
        )
        if (-not $ghosthubActivityIdentity.StartsWith($ghosthubActivityExpected)) {
            Write-Output '\(endedMarker)'
            exit 0
        }
        $ghosthubActivityFields = $ghosthubActivityIdentity -split "`t"
        if (($ghosthubActivityFields.Count -lt 6) -or ($ghosthubActivityFields.Count -gt 7) -or ($ghosthubActivityFields[4] -notmatch '^%\\d+$')) {
            exit 65
        }
        $ghosthubActivityPane = $ghosthubActivityFields[4]
        $ghosthubActivityFormatProbe = (\(formatProbe) 2>&1 | Out-String).Trim()
        if (($LASTEXITCODE -ne 0) -or ($ghosthubActivityFormatProbe -ne '\(supportMarker)')) {
            exit 69
        }
        $ghosthubActivityIfShellProbe = (\(ifShellProbe) 2>&1 | Out-String).Trim()
        if (($LASTEXITCODE -ne 0) -or ($ghosthubActivityIfShellProbe -ne '\(supportMarker)')) {
            exit 69
        }
        $ghosthubActivityHistorySize = (\(historySize) | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { exit 65 }
        if ($ghosthubActivityHistorySize -eq '\(mismatchMarker)') {
            Write-Output '\(endedMarker)'
            exit 0
        }
        if ($ghosthubActivityHistorySize -notmatch '^\\d+$') {
            exit 65
        }
        if ([int64]$ghosthubActivityHistorySize -eq 0) {
            $ghosthubActivityCapture = ''
        } else {
            $ghosthubActivityCapture = (\(capture) | Out-String)
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
        $ghosthubActivityBytes = [System.Text.Encoding]::UTF8.GetBytes($ghosthubActivityCapture)
        $ghosthubActivitySHA = [System.Security.Cryptography.SHA256]::Create()
        try {
            $ghosthubActivityHashBytes = $ghosthubActivitySHA.ComputeHash($ghosthubActivityBytes)
        } finally {
            $ghosthubActivitySHA.Dispose()
        }
        $ghosthubActivityHash = -join ($ghosthubActivityHashBytes | ForEach-Object { $_.ToString('x2') })
        Write-Output (\(
            powerShellEncodedArgument(checksumMarker)
        ) + $ghosthubActivityHash + "`t" + $ghosthubActivityBytes.Length + "`t" + $ghosthubActivityHistorySize)
        \(checkedIdentity)
        """
    }

    private static func powerShellInvocation(
        tmuxPath: String,
        arguments: [String]
    ) -> String {
        "& " + ([tmuxPath] + arguments)
            .map(powerShellEncodedArgument)
            .joined(separator: " ")
    }

    static func parse(
        _ output: String,
        expectedIdentity: TmuxSessionIdentity
    ) -> TmuxSessionActivityProbeResult {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        if lines.last == endedMarker {
            return .ended
        }
        let identities = lines.enumerated().compactMap { index, line in
            parseIdentityLine(line).map { (index, $0) }
        }
        guard identities.count >= 2 else {
            return .unavailable
        }
        let first = identities[identities.count - 2]
        let last = identities[identities.count - 1]
        guard first.1.identity == expectedIdentity,
              last.1.identity == expectedIdentity
        else {
            return .ended
        }
        guard first.1.paneID == last.1.paneID,
              first.1.dimensions == last.1.dimensions
        else {
            return .unavailable
        }
        let fencedLines = lines[(first.0 + 1) ..< last.0]
        guard let checksum = fencedLines
            .reversed()
            .compactMap(parseChecksumLine)
            .first
        else {
            return .unavailable
        }
        return .sample(
            paneID: first.1.paneID,
            dimensions: first.1.dimensions,
            fingerprint: [
                checksum.checksum,
                checksum.byteCount,
                checksum.historySize,
            ]
            .joined(separator: ":"),
            windowCount: first.1.windowCount.flatMap { count in
                count == last.1.windowCount ? count : nil
            }
        )
    }

    private static func parseIdentityLine(
        _ line: String
    ) -> (
        identity: TmuxSessionIdentity,
        paneID: String,
        dimensions: String,
        windowCount: Int?
    )? {
        guard line.hasPrefix(identityMarker) else { return nil }
        let fields = line.dropFirst(identityMarker.count).split(
            separator: "\t",
            maxSplits: 5,
            omittingEmptySubsequences: false
        )
        guard fields.count == 5 || fields.count == 6 else { return nil }
        let identity = TmuxSessionIdentity(
            serverPID: String(fields[0]),
            sessionID: String(fields[1]),
            createdAt: String(fields[2])
        )
        let paneID = String(fields[3])
        let dimensions = String(fields[4])
        let windowCount = fields.count == 6
            ? positiveInt(String(fields[5]))
            : nil
        guard TmuxSessionKiller.isNumericIdentity(identity.serverPID),
              TmuxSessionKiller.isSessionID(identity.sessionID),
              TmuxSessionKiller.isSessionCreatedAt(identity.createdAt),
              paneID.utf8.first == 37,
              paneID.utf8.dropFirst().allSatisfy({ byte in
                  byte >= 48 && byte <= 57
              }),
              isDimensions(dimensions)
        else { return nil }
        return (identity, paneID, dimensions, windowCount)
    }

    private static func parseChecksumLine(
        _ line: String
    ) -> (checksum: String, byteCount: String, historySize: String)? {
        guard line.hasPrefix(checksumMarker) else { return nil }
        let fields = line.dropFirst(checksumMarker.count).split(
            separator: "\t",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3,
              isChecksum(String(fields[0])),
              isNumeric(String(fields[1])),
              isNumeric(String(fields[2]))
        else { return nil }
        return (
            String(fields[0]),
            String(fields[1]),
            String(fields[2])
        )
    }

    private static func isDimensions(_ value: String) -> Bool {
        let sides = value.split(
            separator: "x",
            omittingEmptySubsequences: false
        )
        return sides.count == 2 && sides.allSatisfy { side in
            isNumeric(String(side))
        }
    }

    private static func isChecksum(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 97 && byte <= 102)
        }
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte >= 48 && byte <= 57
        }
    }

    private static func positiveInt(_ value: String) -> Int? {
        guard isNumeric(value), let parsed = Int(value), parsed > 0 else {
            return nil
        }
        return parsed
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

    private static func resolveTmuxPath(
        on host: CommandHost,
        sshConnectionArguments: [String]?
    ) -> Result<String, TmuxBinaryError> {
        let resolver = TmuxBinaryResolver()
        return switch host {
        case .local:
            resolver.resolveTmuxPath()
        case let .ssh(info):
            resolver.resolveTmuxPath(
                on: info,
                sshConnectionArguments: sshConnectionArguments ?? []
            )
        }
    }
}

private final class TmuxSessionActivityPathCache: @unchecked Sendable {
    typealias Resolver = @Sendable (CommandHost, [String]?)
        -> Result<String, TmuxBinaryError>

    private let lock = NSLock()
    private var paths: [CommandHost: String] = [:]
    private let resolve: Resolver

    init(resolve: @escaping Resolver) {
        self.resolve = resolve
    }

    func resolve(
        on host: CommandHost,
        sshConnectionArguments: [String]?
    ) -> Result<String, TmuxBinaryError> {
        lock.lock()
        if let path = paths[host] {
            lock.unlock()
            return .success(path)
        }
        lock.unlock()
        let result = resolve(host, sshConnectionArguments)
        if case let .success(path) = result {
            lock.lock()
            paths[host] = path
            lock.unlock()
        }
        return result
    }
}
