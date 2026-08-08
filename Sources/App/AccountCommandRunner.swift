import Darwin
import Foundation
import GhosthubHerdr
import GhosthubTmux
import GhosthubTransport

struct AccountCommandOutput: Equatable, Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

private final class AccountCommandOutputCollector: @unchecked Sendable {
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

struct AccountCommandRunner: Sendable {
    static let timedOutStatus: Int32 = -124
    static let outputExceededStatus: Int32 = -125
    static let cancelledStatus: Int32 = -130
    private static let maximumOutputBytes = 1 * 1_024 * 1_024

    typealias ProcessRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval,
        _ environmentOverrides: [String: String]
    ) -> AccountCommandOutput

    private let processRunner: ProcessRunner
    private let loginShellProvider: @Sendable () -> String

    init(
        processRunner: @escaping ProcessRunner = Self.runProcess,
        loginShellProvider: @escaping @Sendable () -> String = Self.loginShell
    ) {
        self.processRunner = processRunner
        self.loginShellProvider = loginShellProvider
    }

    func runLocalLoginShell(
        command: String,
        timeout: TimeInterval,
        environmentOverrides: [String: String] = [:]
    ) -> AccountCommandOutput {
        processRunner(
            loginShellProvider(),
            ["-lc", accountShellCommand(command)],
            timeout,
            environmentOverrides
        )
    }

    func runRemoteLoginShell(
        host: SSHHostInfo,
        connectionArguments: [String],
        command: String,
        timeout: TimeInterval
    ) -> AccountCommandOutput {
        let invocation = (["/usr/bin/ssh"] + Self.remoteLoginArguments(
            host: host,
            connectionArguments: connectionArguments,
            command: command
        )).map(shellQuotedCommandArgument).joined(separator: " ")
        return runLocalLoginShell(command: invocation, timeout: timeout)
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
        timeout: TimeInterval,
        captureStandardError: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) -> (status: Int32, stdout: String) {
        let output = AccountCommandRunner(
            loginShellProvider: { shell }
        ).runLocalLoginShell(
            command: command,
            timeout: timeout,
            environmentOverrides: environmentOverrides
        )
        return (
            output.status,
            captureStandardError
                ? output.stdout + output.stderr
                : output.stdout
        )
    }

    static func runProcessInLoginShell(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        captureStandardError: Bool = false,
        accountShell: String = loginShell(),
        environmentOverrides: [String: String] = [:]
    ) -> (status: Int32, stdout: String) {
        let command = ([executable] + arguments)
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        return runLoginShell(
            shell: accountShell,
            command: command,
            timeout: timeout,
            captureStandardError: captureStandardError,
            environmentOverrides: environmentOverrides
        )
    }

    static func runRemoteLoginShell(
        host: SSHHostInfo,
        command: String,
        timeout: TimeInterval,
        accountShell: String = loginShell(),
        captureStandardError: Bool = false
    ) -> (status: Int32, stdout: String) {
        let output = AccountCommandRunner(
            loginShellProvider: { accountShell }
        ).runRemoteLoginShell(
            host: host,
            connectionArguments: defaultConnectionArguments(for: host),
            command: command,
            timeout: timeout
        )
        return (
            output.status,
            captureStandardError
                ? output.stdout + output.stderr
                : output.stdout
        )
    }

    static func runRemoteLoginShellSeparatingStandardError(
        host: SSHHostInfo,
        command: String,
        timeout: TimeInterval,
        accountShell: String = loginShell()
    ) -> AccountCommandOutput {
        AccountCommandRunner(
            loginShellProvider: { accountShell }
        ).runRemoteLoginShell(
            host: host,
            connectionArguments: defaultConnectionArguments(for: host),
            command: command,
            timeout: timeout
        )
    }

    static func remoteLoginCommand(
        host: SSHHostInfo,
        command: String
    ) -> String {
        if host.platform == .windows {
            return powerShellEncodedCommand(command)
        }
        return accountLoginShellCommand(command)
    }

    static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environmentOverrides: [String: String] = [:]
    ) -> AccountCommandOutput {
        var outputDescriptors = [Int32](repeating: -1, count: 2)
        guard outputDescriptors.withUnsafeMutableBufferPointer({ descriptors in
            pipe(descriptors.baseAddress!)
        }) == 0 else {
            return AccountCommandOutput(status: 127, stdout: "", stderr: "")
        }
        let outputRead = outputDescriptors[0]
        let outputWrite = outputDescriptors[1]
        var errorDescriptors = [Int32](repeating: -1, count: 2)
        guard errorDescriptors.withUnsafeMutableBufferPointer({ descriptors in
            pipe(descriptors.baseAddress!)
        }) == 0 else {
            close(outputRead)
            close(outputWrite)
            return AccountCommandOutput(status: 127, stdout: "", stderr: "")
        }
        let errorRead = errorDescriptors[0]
        let errorWrite = errorDescriptors[1]
        var fileActions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(
            &fileActions, outputWrite, STDOUT_FILENO
        )
        posix_spawn_file_actions_adddup2(
            &fileActions, errorWrite, STDERR_FILENO
        )
        posix_spawn_file_actions_addclose(&fileActions, outputRead)
        posix_spawn_file_actions_addclose(&fileActions, outputWrite)
        posix_spawn_file_actions_addclose(&fileActions, errorRead)
        posix_spawn_file_actions_addclose(&fileActions, errorWrite)
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
        var environment = sanitizedProcessEnvironment(
            ProcessInfo.processInfo.environment
        )
        environment.merge(environmentOverrides) { _, override in override }
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
        close(errorWrite)
        guard spawnStatus == 0 else {
            close(outputRead)
            close(errorRead)
            return AccountCommandOutput(status: 127, stdout: "", stderr: "")
        }

        defer { close(outputRead) }
        defer { close(errorRead) }
        let outputFlags = fcntl(outputRead, F_GETFL)
        let errorFlags = fcntl(errorRead, F_GETFL)
        guard outputFlags >= 0,
              errorFlags >= 0,
              fcntl(
                  outputRead,
                  F_SETFL,
                  outputFlags | O_NONBLOCK
              ) == 0,
              fcntl(errorRead, F_SETFL, errorFlags | O_NONBLOCK) == 0 else {
            kill(-processID, SIGKILL)
            var waitStatus = Int32(0)
            _ = waitpid(processID, &waitStatus, 0)
            return AccountCommandOutput(status: 127, stdout: "", stderr: "")
        }
        let output = AccountCommandOutputCollector(
            limit: maximumOutputBytes
        )
        let errorOutput = AccountCommandOutputCollector(
            limit: maximumOutputBytes
        )
        var readBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
        let deadline = Date().addingTimeInterval(timeout)
        var interruptedStatus: Int32?
        var waitStatus = Int32(0)
        var processFinished = false
        var outputReachedEOF = false
        var errorReachedEOF = false
        let maximumReadsPerDrain = 16

        func currentInterruptionStatus() -> Int32? {
            if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
                return cancelledStatus
            }
            if Date() >= deadline {
                return timedOutStatus
            }
            if output.didOverflow || errorOutput.didOverflow {
                return outputExceededStatus
            }
            return nil
        }

        func drain(
            descriptor: Int32,
            collector: AccountCommandOutputCollector,
            reachedEOF: inout Bool
        ) {
            var readsRemaining = maximumReadsPerDrain
            while !reachedEOF, readsRemaining > 0 {
                let count = read(descriptor, &readBuffer, readBuffer.count)
                readsRemaining -= 1
                if count > 0 {
                    collector.append(Data(readBuffer.prefix(Int(count))))
                    continue
                }
                if count == 0 {
                    reachedEOF = true
                    break
                }
                if errno == EINTR {
                    continue
                }
                if errno != EAGAIN, errno != EWOULDBLOCK {
                    reachedEOF = true
                }
                break
            }
        }

        while !processFinished || !outputReachedEOF || !errorReachedEOF {
            drain(
                descriptor: outputRead,
                collector: output,
                reachedEOF: &outputReachedEOF
            )
            drain(
                descriptor: errorRead,
                collector: errorOutput,
                reachedEOF: &errorReachedEOF
            )
            if let status = currentInterruptionStatus() {
                interruptedStatus = status
            }
            if interruptedStatus != nil {
                break
            }
            if !processFinished {
                let waited = waitpid(processID, &waitStatus, WNOHANG)
                processFinished = waited == processID
            }
            if processFinished, outputReachedEOF, errorReachedEOF {
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
            return AccountCommandOutput(
                status: interruptedStatus,
                stdout: "",
                stderr: ""
            )
        }
        let collected = output.snapshot()
        let collectedError = errorOutput.snapshot()
        if collected.overflowed || collectedError.overflowed {
            return AccountCommandOutput(
                status: outputExceededStatus,
                stdout: "",
                stderr: ""
            )
        }
        return AccountCommandOutput(
            status: exitStatus(from: waitStatus),
            stdout: String(decoding: collected.data, as: UTF8.self),
            stderr: String(decoding: collectedError.data, as: UTF8.self)
        )
    }

    static func sanitizedProcessEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        environment.filter {
            $0.key != "TMUX"
                && $0.key != "TMUX_PANE"
                && !HerdrEnvironment.controlVariables.contains($0.key)
        }
    }

    private static func defaultConnectionArguments(
        for host: SSHHostInfo
    ) -> [String] {
        tmuxSSHConnectionArguments()
            + SSHConnectionPool.connectionArguments(for: host)
            + SSHConfigurationResolver.noninteractiveHostKeyArguments(for: host)
    }

    private static func remoteLoginArguments(
        host: SSHHostInfo,
        connectionArguments: [String],
        command: String
    ) -> [String] {
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        arguments.append(contentsOf: connectionArguments)
        if let port = host.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        let target = host.user.map { "\($0)@\(host.hostname)" } ?? host.hostname
        arguments.append(contentsOf: [
            "--", target, remoteLoginCommand(host: host, command: command),
        ])
        return arguments
    }

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        if waitStatus & 0x7f == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + (waitStatus & 0x7f)
    }
}
