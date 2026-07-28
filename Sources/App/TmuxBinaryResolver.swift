import Darwin
import Foundation
import GhosthubTmux

private final class TmuxProbeOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var overflowed = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining {
            overflowed = true
        }
    }

    func snapshot() -> (data: Data, overflowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, overflowed)
    }

    var didOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }
}

enum TmuxBinaryError: Error, Equatable, LocalizedError, Sendable {
    case notFound(shell: String)
    case shellFailed(status: Int32)
    case sshConnectionFailed(host: String)
    case probeTimedOut(shell: String)
    case probeCancelled(shell: String)
    case probeOutputExceeded(shell: String)
    case sessionContextUnavailable
    case unsupportedVersion(found: String)
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
        case let .sshConnectionFailed(host):
            return "SSH could not connect to \(host). Open Host Settings and"
                + " run Test Connection to verify the host key,"
                + " authentication, and network access."
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
        case let .unsupportedVersion(found):
            return "Ghosthub requires tmux 3.2 or newer, but found"
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
    var managed: Bool

    init(
        name: String,
        windowCount: Int,
        serverPID: String? = nil,
        sessionID: String? = nil,
        createdAt: String?,
        managed: Bool
    ) {
        self.name = name
        self.windowCount = windowCount
        self.serverPID = serverPID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.managed = managed
    }
}

/// Resolves the tmux binary through the user's login shell, because a
/// launchd-launched GUI app does not inherit Homebrew or user-bin PATH
/// entries. Reads the passwd shell (not $SHELL, which may be absent).
struct TmuxBinaryResolver: Sendable {
    private static let timedOutStatus: Int32 = -124
    private static let outputExceededStatus: Int32 = -125
    private static let cancelledStatus: Int32 = -130
    private static let maximumProbeOutputBytes = 1 * 1_024 * 1_024
    typealias ProcessRunner = @Sendable (_ shell: String, _ command: String)
        -> (status: Int32, stdout: String)
    typealias RemoteProcessRunner = @Sendable (
        _ host: SSHHostInfo, _ command: String
    ) -> (status: Int32, stdout: String)

    private let processRunner: ProcessRunner
    private let remoteProcessRunner: RemoteProcessRunner
    private let loginShellProvider: @Sendable () -> String

    init(
        processRunner: ProcessRunner? = nil,
        remoteProcessRunner: RemoteProcessRunner? = nil,
        processTimeout: TimeInterval = 15,
        loginShellProvider: @escaping @Sendable () -> String = Self.loginShell
    ) {
        self.processRunner = processRunner ?? { shell, command in
            Self.runLoginShell(
                shell: shell, command: command, timeout: processTimeout
            )
        }
        self.remoteProcessRunner = remoteProcessRunner ?? { host, command in
            Self.runRemoteLoginShell(
                host: host, command: command, timeout: processTimeout
            )
        }
        self.loginShellProvider = loginShellProvider
    }

    func resolveTmuxPath() -> Result<String, TmuxBinaryError> {
        let shell = loginShellProvider()
        let result = processRunner(shell, Self.probeCommand)
        return Self.parseProbe(result, shell: shell)
    }

    func resolveTmuxPath(on host: SSHHostInfo) -> Result<String, TmuxBinaryError> {
        let result = remoteProcessRunner(
            host,
            Self.probeCommand(for: host.platform)
        )
        if result.status == 255 {
            return .failure(.sshConnectionFailed(host: host.displayName))
        }
        return Self.parseProbe(result, shell: host.displayName)
    }

    func discoverSessions() -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        let shell = loginShellProvider()
        return Self.parseDiscovery(
            processRunner(shell, Self.discoveryCommand),
            shell: shell
        )
    }

    func discoverSessions(
        on host: SSHHostInfo
    ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        let result = remoteProcessRunner(
            host,
            Self.discoveryCommand(for: host.platform)
        )
        if result.status == 255 {
            return .failure(.sshConnectionFailed(host: host.displayName))
        }
        return Self.parseDiscovery(
            result,
            shell: host.displayName
        )
    }

    private static let probeCommand =
        "ghosthub_tmux_path=$(command -v tmux) || exit $?; "
            + "printf '%s\\n' \"$ghosthub_tmux_path\"; "
            + "\"$ghosthub_tmux_path\" -V"

    private static let discoveryPrefix = "GHOSTHUB_TMUX_SESSION"
    private static let discoveryFormat = discoveryPrefix
        + "\t#{session_windows}\t#{pid}\t#{session_id}\t#{session_created}"
        + "\t#{@ghosthub_owner}\t#{session_name}"
    private static let discoveryCommand = probeCommand
        + "; ghosthub_tmux_status=0; "
        + "\"$ghosthub_tmux_path\" list-sessions -F "
        + shellQuotedCommandArgument(discoveryFormat)
        + " 2>/dev/null || ghosthub_tmux_status=$?; "
        + "[ \"$ghosthub_tmux_status\" -eq 0 ]"
        + " || [ \"$ghosthub_tmux_status\" -eq 1 ]"

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
            & $ghosthubMux 'list-sessions' '-F' \(powerShellQuotedCommandArgument(discoveryFormat))
            $ghosthubMuxStatus = $LASTEXITCODE
            if (($ghosthubMuxStatus -eq 0) -or ($ghosthubMuxStatus -eq 1)) {
                exit 0
            }
            exit $ghosthubMuxStatus
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
        shell: String
    ) -> Result<String, TmuxBinaryError> {
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
        guard isSupported(version) else {
            return .failure(.unsupportedVersion(found: version))
        }
        return .success(path)
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
        shell: String
    ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        switch parseProbe(result, shell: shell) {
        case let .failure(error):
            return .failure(error)
        case .success:
            break
        }
        let prefix = discoveryPrefix + "\t"
        let sessions = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> DiscoveredTmuxSession? in
                let line = String(rawLine)
                guard line.hasPrefix(prefix) else { return nil }
                let fields = line.split(
                    separator: "\t",
                    maxSplits: 6,
                    omittingEmptySubsequences: false
                )
                guard fields.count == 7,
                      let windowCount = Int(fields[1]),
                      windowCount >= 0
                else { return nil }
                return DiscoveredTmuxSession(
                    name: String(fields[6]),
                    windowCount: windowCount,
                    serverPID: fields[2].isEmpty ? nil : String(fields[2]),
                    sessionID: fields[3].isEmpty ? nil : String(fields[3]),
                    createdAt: fields[4].isEmpty ? nil : String(fields[4]),
                    managed: !fields[5].isEmpty
                )
            }
        return .success(sessions)
    }

    private static func isSupported(_ output: String) -> Bool {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "tmux" else { return false }
        let components = fields[1].split(separator: ".", maxSplits: 1)
        guard components.count == 2,
              let major = Int(components[0]) else { return false }
        let minorDigits = components[1].prefix(while: \.isNumber)
        guard let minor = Int(minorDigits) else { return false }
        return major > 3 || (major == 3 && minor >= 2)
    }

    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let value = String(cString: shell)
            if !value.isEmpty {
                return value
            }
        }
        return "/bin/zsh"
    }

    static func runLoginShell(
        shell: String,
        command: String,
        timeout: TimeInterval
    ) -> (status: Int32, stdout: String) {
        runProcess(
            executable: shell,
            arguments: ["-lc", posixCommand(command)],
            timeout: timeout
        )
    }

    static func runRemoteLoginShell(
        host: SSHHostInfo,
        command: String,
        timeout: TimeInterval
    ) -> (status: Int32, stdout: String) {
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        arguments.append(contentsOf: tmuxSSHConnectionArguments())
        if let port = host.port, port != 22 {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        let target = host.user.map { "\($0)@\(host.hostname)" } ?? host.hostname
        let accountShellCommand = "exec \"${SHELL:-/bin/sh}\" -lc "
            + shellQuotedCommandArgument(posixCommand(command))
        let loginCommand = posixCommand(accountShellCommand)
        arguments.append(contentsOf: ["--", target, loginCommand])
        return runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            timeout: timeout
        )
    }

    /// The account shell owns login-environment initialization, but Ghosthub's
    /// command language is POSIX shell. Keep the command handed to fish, zsh,
    /// or another account shell to one portable simple-command invocation.
    private static func posixCommand(_ command: String) -> String {
        "exec /bin/sh -c " + shellQuotedCommandArgument(command)
    }

    static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        captureStandardError: Bool = false
    ) -> (status: Int32, stdout: String) {
        var outputDescriptors = [Int32](repeating: -1, count: 2)
        guard outputDescriptors.withUnsafeMutableBufferPointer({ descriptors in
            pipe(descriptors.baseAddress!)
        }) == 0 else {
            return (status: 127, stdout: "")
        }
        let outputRead = outputDescriptors[0]
        let outputWrite = outputDescriptors[1]
        let nullDescriptor = open("/dev/null", O_WRONLY)
        guard nullDescriptor >= 0 else {
            close(outputRead)
            close(outputWrite)
            return (status: 127, stdout: "")
        }
        var fileActions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
            close(nullDescriptor)
        }
        posix_spawn_file_actions_adddup2(
            &fileActions, outputWrite, STDOUT_FILENO
        )
        posix_spawn_file_actions_adddup2(
            &fileActions,
            captureStandardError ? outputWrite : nullDescriptor,
            STDERR_FILENO
        )
        posix_spawn_file_actions_addclose(&fileActions, outputRead)
        posix_spawn_file_actions_addclose(&fileActions, outputWrite)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        var processID = pid_t(0)
        let argumentStrings = [executable] + arguments
        var cArguments = argumentStrings.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        cArguments.append(nil)
        let environment = sanitizedProcessEnvironment(
            ProcessInfo.processInfo.environment
        )
        var cEnvironment = environment.map {
            strdup("\($0.key)=\($0.value)")
        }
        defer { cEnvironment.forEach { free($0) } }
        cEnvironment.append(nil)
        let spawnStatus = executable.withCString { executablePath in
            cArguments.withUnsafeMutableBufferPointer { arguments in
                cEnvironment.withUnsafeMutableBufferPointer { environment in
                    posix_spawn(
                        &processID,
                        executablePath,
                        &fileActions,
                        &attributes,
                        arguments.baseAddress!,
                        environment.baseAddress!
                    )
                }
            }
        }
        close(outputWrite)
        guard spawnStatus == 0 else {
            close(outputRead)
            return (status: 127, stdout: "")
        }

        defer { close(outputRead) }
        let currentFlags = fcntl(outputRead, F_GETFL)
        guard currentFlags >= 0,
              fcntl(outputRead, F_SETFL, currentFlags | O_NONBLOCK) == 0
        else {
            kill(-processID, SIGKILL)
            var waitStatus = Int32(0)
            _ = waitpid(processID, &waitStatus, 0)
            return (status: 127, stdout: "")
        }
        let output = TmuxProbeOutputCollector(
            limit: maximumProbeOutputBytes
        )
        var readBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
        let deadline = Date().addingTimeInterval(timeout)
        var interruptedStatus: Int32?
        var waitStatus = Int32(0)
        var processFinished = false
        var outputReachedEOF = false
        let maximumReadsPerDrain = 16

        func currentInterruptionStatus() -> Int32? {
            if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
                return cancelledStatus
            }
            if Date() >= deadline {
                return timedOutStatus
            }
            if output.didOverflow {
                return outputExceededStatus
            }
            return nil
        }

        while !processFinished || !outputReachedEOF {
            var readsRemaining = maximumReadsPerDrain
            while !outputReachedEOF, readsRemaining > 0 {
                let count = read(outputRead, &readBuffer, readBuffer.count)
                readsRemaining -= 1
                if count > 0 {
                    output.append(Data(readBuffer.prefix(Int(count))))
                    if let status = currentInterruptionStatus() {
                        interruptedStatus = status
                        break
                    }
                    continue
                }
                if count == 0 {
                    outputReachedEOF = true
                    break
                }
                if errno == EINTR {
                    continue
                }
                if errno != EAGAIN, errno != EWOULDBLOCK {
                    outputReachedEOF = true
                }
                break
            }
            if interruptedStatus != nil {
                break
            }
            if !processFinished {
                let waited = waitpid(processID, &waitStatus, WNOHANG)
                processFinished = waited == processID
            }
            if processFinished, outputReachedEOF {
                break
            }
            if let status = currentInterruptionStatus() {
                interruptedStatus = status
                break
            }
            usleep(10_000)
        }
        if let interruptedStatus {
            // The child is the leader of an isolated process group. Negative
            // PID delivery reaches the login shell/SSH process and every
            // descendant, even if the leader has already exited.
            kill(-processID, SIGTERM)
            usleep(100_000)
            kill(-processID, SIGKILL)
            // Give orphaned descendants a brief chance to be reaped before
            // returning. This remains bounded and avoids leaking a killed
            // login-shell child into the caller's next probe.
            usleep(100_000)
            if !processFinished {
                _ = waitpid(processID, &waitStatus, 0)
            }
            return (status: interruptedStatus, stdout: "")
        }
        let collected = output.snapshot()
        if collected.overflowed {
            return (status: outputExceededStatus, stdout: "")
        }
        return (
            status: exitStatus(from: waitStatus),
            stdout: String(decoding: collected.data, as: UTF8.self)
        )
    }

    static func sanitizedProcessEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        environment.filter { $0.key != "TMUX" && $0.key != "TMUX_PANE" }
    }

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        if waitStatus & 0x7f == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + (waitStatus & 0x7f)
    }
}
