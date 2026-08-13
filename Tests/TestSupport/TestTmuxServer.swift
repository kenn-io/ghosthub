import Darwin
import Foundation

public enum TestTmuxServerError: Error, CustomStringConvertible, Sendable {
    case invalidEnvironment(String)
    case invalidSocket(String)
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    case commandTimedOut(arguments: [String])

    public var description: String {
        switch self {
        case let .invalidEnvironment(message), let .invalidSocket(message):
            message
        case let .commandFailed(arguments, status, stderr):
            "tmux \(arguments.joined(separator: " ")) exited \(status): \(stderr)"
        case let .commandTimedOut(arguments):
            "tmux \(arguments.joined(separator: " ")) timed out"
        }
    }
}

public struct TestTmuxCommandOutput: Sendable {
    public let status: Int32
    public let stderr: String

    public init(status: Int32, stderr: String) {
        self.status = status
        self.stderr = stderr
    }
}

public final class TestTmuxServer: @unchecked Sendable {
    public typealias CommandRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval,
        _ environment: [String: String]
    ) throws -> TestTmuxCommandOutput

    public enum SocketKind: Sendable {
        case runOwned(purpose: String)
        case productContract(name: String)
    }

    public let socketName: String
    public let socketPath: String?
    public let connectionArguments: [String]

    private let tmuxPath: String
    private let commandRunner: CommandRunner
    private let environment: [String: String]
    private let lock = NSLock()
    private var stopped = false

    public init(
        tmuxPath: String,
        socket: SocketKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: CommandRunner? = nil
    ) throws {
        let context = try Self.wrapperContext(environment: environment)
        self.tmuxPath = tmuxPath
        self.commandRunner = commandRunner ?? Self.run
        self.environment = environment

        switch socket {
        case let .runOwned(purpose):
            socketName = try Self.runOwnedSocketName(
                purpose: purpose,
                context: context
            )
            socketPath = nil
            connectionArguments = ["-L", socketName]
        case let .productContract(name):
            try Self.validateSocketComponent(name, label: "product socket name")
            socketName = name
            let socketDirectory = URL(fileURLWithPath: context.tmuxDirectory)
                .appendingPathComponent("tmux-\(getuid())", isDirectory: true)
                .path
            try Self.prepareSocketDirectory(socketDirectory)
            let path = URL(fileURLWithPath: socketDirectory)
                .appendingPathComponent(name, isDirectory: false).path
            guard path.hasPrefix(context.tmuxDirectory + "/") else {
                throw TestTmuxServerError.invalidSocket(
                    "product socket escaped the private tmux directory"
                )
            }
            socketPath = path
            connectionArguments = ["-S", path]
        }
    }

    deinit {
        stop()
    }

    public static func runOwnedSocketName(
        purpose: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        try runOwnedSocketName(
            purpose: purpose,
            context: wrapperContext(environment: environment)
        )
    }

    public func createSession(
        _ name: String,
        command: String? = nil
    ) throws {
        try Self.validateSocketComponent(name, label: "session name")
        var arguments = ["-f", "/dev/null"]
            + connectionArguments
            + ["new-session", "-d", "-s", name]
        if let command {
            arguments.append(command)
        }
        let result = try commandRunner(tmuxPath, arguments, 10, environment)
        guard result.status == 0 else {
            throw TestTmuxServerError.commandFailed(
                arguments: arguments,
                status: result.status,
                stderr: result.stderr
            )
        }
        lock.withLock {
            stopped = false
        }
    }

    public func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        _ = try? commandRunner(
            tmuxPath,
            connectionArguments + ["kill-server"],
            5,
            environment
        )
    }

    private struct WrapperContext {
        let runID: String
        let tmuxDirectory: String
    }

    private static func wrapperContext(
        environment: [String: String]
    ) throws -> WrapperContext {
        guard let runID = environment["GHOSTHUB_TEST_TMUX_RUN_ID"],
              runID.count == 6,
              runID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) && $0.isASCII
              })
        else {
            throw TestTmuxServerError.invalidEnvironment(
                "real tmux tests require a six-character alphanumeric "
                    + "GHOSTHUB_TEST_TMUX_RUN_ID from make swift-test"
            )
        }
        guard let tmuxDirectory = environment["TMUX_TMPDIR"],
              tmuxDirectory.first == "/"
        else {
            throw TestTmuxServerError.invalidEnvironment(
                "real tmux tests require an absolute TMUX_TMPDIR from make swift-test"
            )
        }
        let expectedPrefix = "/tmp/ghosthub-\(getuid())/tmux-tests/run."
        let components = tmuxDirectory.split(separator: "/")
        guard tmuxDirectory.hasPrefix(expectedPrefix),
              components.count == 4,
              components[1] == "ghosthub-\(getuid())",
              components[2] == "tmux-tests"
        else {
            throw TestTmuxServerError.invalidEnvironment(
                "TMUX_TMPDIR is outside the standardized Ghosthub test root"
            )
        }
        let runComponents = components[3].split(separator: ".")
        guard runComponents.count == 3,
              runComponents[0] == "run",
              (Int32(runComponents[1]) ?? 0) > 0,
              runComponents[2] == Substring(runID)
        else {
            throw TestTmuxServerError.invalidEnvironment(
                "TMUX_TMPDIR does not match GHOSTHUB_TEST_TMUX_RUN_ID"
            )
        }

        var statBuffer = stat()
        guard lstat(tmuxDirectory, &statBuffer) == 0,
              statBuffer.st_uid == getuid(),
              statBuffer.st_mode & S_IFMT == S_IFDIR,
              statBuffer.st_mode & 0o777 == 0o700
        else {
            throw TestTmuxServerError.invalidEnvironment(
                "TMUX_TMPDIR must be an owned mode-0700 directory"
            )
        }
        return WrapperContext(runID: runID, tmuxDirectory: tmuxDirectory)
    }

    private static func runOwnedSocketName(
        purpose: String,
        context: WrapperContext
    ) throws -> String {
        try validateSocketComponent(purpose, label: "socket purpose")
        guard purpose.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw TestTmuxServerError.invalidSocket(
                "socket purpose must contain only letters, numbers, and hyphens"
            )
        }
        return "ghosthub-\(purpose)-\(context.runID)"
    }

    private static func validateSocketComponent(
        _ value: String,
        label: String
    ) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0")
        else {
            throw TestTmuxServerError.invalidSocket("invalid \(label)")
        }
    }

    private static func prepareSocketDirectory(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            guard FileManager.default.fileExists(atPath: path) else {
                throw error
            }
            // A sibling fixture in the same wrapped run may already own it.
        }
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0,
              statBuffer.st_uid == getuid(),
              statBuffer.st_mode & S_IFMT == S_IFDIR,
              statBuffer.st_mode & 0o777 == 0o700
        else {
            throw TestTmuxServerError.invalidEnvironment(
                "private tmux socket directory must be owned and mode 0700"
            )
        }
    }

    private static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]
    ) throws -> TestTmuxCommandOutput {
        let process = Process()
        let stderr = Pipe()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.terminationHandler = { _ in completed.signal() }
        try process.run()

        if completed.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw TestTmuxServerError.commandTimedOut(arguments: arguments)
        }
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        return TestTmuxCommandOutput(
            status: process.terminationStatus,
            stderr: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
