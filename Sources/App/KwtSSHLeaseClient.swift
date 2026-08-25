import Darwin
import Foundation

enum KwtSSHLeaseMode: String, Decodable, Equatable, Sendable {
    case multiplexed
    case masterless
}

enum KwtSSHHostKeyPolicy: String, Sendable {
    case review
    case strict
}

struct KwtSSHLeaseResult: Decodable, Equatable, Sendable {
    let leaseID: String
    let routeIdentity: String
    let generation: UInt64
    let mode: KwtSSHLeaseMode
    let arguments: [String]

    private enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case routeIdentity = "route_identity"
        case generation
        case mode
        case arguments
    }
}

enum KwtSSHLeasePromptKind: String, Decodable, Equatable, Sendable {
    case authentication = "ssh_authentication"
    case hostKey = "ssh_host_key"
}

struct KwtSSHHostKeyReview: Decodable, Equatable, Sendable {
    let host: String
    let algorithm: String
    let fingerprint: String
}

struct KwtSSHLeasePromptDetails: Decodable, Equatable, Sendable {
    let logicalTarget: KwtSSHTarget
    let effectiveTarget: KwtSSHTarget
    let displayTarget: String
    let hopIndex: Int
    let hopCount: Int
    let hostKey: KwtSSHHostKeyReview?

    private enum CodingKeys: String, CodingKey {
        case logicalTarget = "logical_target"
        case effectiveTarget = "effective_target"
        case displayTarget = "display_target"
        case hopIndex = "hop_index"
        case hopCount = "hop_count"
        case hostKey = "host_key"
    }
}

struct KwtSSHLeasePrompt: Decodable, Equatable, Sendable {
    let id: String
    let kind: KwtSSHLeasePromptKind
    let message: String
    let sensitive: Bool
    let deadline: String
    let details: KwtSSHLeasePromptDetails
}

struct KwtSSHLeasePromptResponse: Codable, Equatable, Sendable {
    let promptID: String
    let value: String

    private enum CodingKeys: String, CodingKey {
        case promptID = "prompt_id"
        case value
    }
}

enum KwtSSHLeaseError: Error, Equatable, LocalizedError, Sendable {
    case helperUnavailable
    case launchFailed
    case malformedEvent
    case acquisitionTimedOut
    case persistentUnsupported
    case cleanupFailed
    case operationFailed(code: String, message: String, retryable: Bool)
    case commandFailed(status: Int32)
    case routeChanged
    case releaseTimedOut
    case poolClosed

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "Ghosthub's bundled kwt helper is unavailable."
        case .launchFailed:
            "Ghosthub could not start its kwt helper."
        case .malformedEvent:
            "kwt returned an invalid SSH lifecycle event."
        case .acquisitionTimedOut:
            "SSH connection preparation stopped responding."
        case .persistentUnsupported:
            "This SSH connection cannot provide a persistent multiplexed lease."
        case .cleanupFailed:
            "Ghosthub could not finish cleaning up the SSH connection."
        case let .operationFailed(_, message, _):
            message
        case let .commandFailed(status):
            "kwt SSH lifecycle failed with status \(status)."
        case .routeChanged:
            "The effective SSH configuration changed."
        case .releaseTimedOut:
            "kwt did not release the SSH connection lease in time."
        case .poolClosed:
            "Ghosthub is shutting down its SSH connections."
        }
    }

    var code: String {
        switch self {
        case .helperUnavailable, .launchFailed, .malformedEvent,
             .commandFailed:
            "ssh_connection_failed"
        case .acquisitionTimedOut:
            "ssh_acquisition_timed_out"
        case .persistentUnsupported:
            "ssh_persistent_unsupported"
        case .cleanupFailed, .releaseTimedOut:
            "ssh_cleanup_failed"
        case let .operationFailed(code, _, _):
            code
        case .routeChanged:
            "ssh_configuration_changed"
        case .poolClosed:
            "ssh_connection_changed"
        }
    }
}

protocol KwtSSHLeaseHolding: Sendable {
    var result: KwtSSHLeaseResult { get }
    var terminalFailure: Task<KwtSSHLeaseError?, Never> { get }
    func release(timeout: Duration) async throws
}

final class KwtSSHLease: KwtSSHLeaseHolding, @unchecked Sendable {
    let result: KwtSSHLeaseResult
    let terminalFailure: Task<KwtSSHLeaseError?, Never>

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let lines: SSHLeaseLineReader
    private let lock = NSLock()
    private var released = false
    private var releaseFailure: KwtSSHLeaseError?
    private var inputClosed = false
    private var forcedTermination = false
    private let terminationIntent: KwtSSHLeaseTerminationIntent

    fileprivate init(
        result: KwtSSHLeaseResult,
        process: Process,
        input: FileHandle,
        output: FileHandle,
        lines: SSHLeaseLineReader
    ) {
        self.result = result
        self.process = process
        self.input = input
        self.output = output
        self.lines = lines
        let terminationIntent = KwtSSHLeaseTerminationIntent()
        self.terminationIntent = terminationIntent
        terminalFailure = Task {
            await Self.monitorTerminal(
                process: process,
                lines: lines,
                terminationIntent: terminationIntent
            )
        }
    }

    deinit {
        let shouldRelease = lock.withLock {
            let value = !released
            released = true
            return value
        }
        guard shouldRelease else { return }
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
        try? output.close()
        lines.cancel()
        terminalFailure.cancel()
    }

    func release(timeout: Duration = .seconds(2)) async throws {
        let releaseState = lock.withLock {
            let closeInput = !inputClosed
            inputClosed = true
            return (
                released: released,
                failure: releaseFailure,
                closeInput: closeInput
            )
        }
        if let failure = releaseState.failure {
            throw failure
        }
        guard !releaseState.released else { return }

        if releaseState.closeInput {
            terminationIntent.beginRelease()
            do {
                try input.close()
            } catch {
                terminationIntent.cancelRelease()
                lock.withLock { inputClosed = false }
                throw error
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            try await withTaskCancellationHandler {
                while process.isRunning, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
            } onCancel: { [self] in
                terminateForCleanup()
            }
        } catch {
            throw error
        }
        if process.isRunning {
            terminateForCleanup()
            throw KwtSSHLeaseError.releaseTimedOut
        }
        let terminalFailure = await terminalFailure.value
        try? output.close()
        lines.cancel()
        let forced = lock.withLock { forcedTermination }
        if !forced, let failure = terminalFailure {
            lock.withLock {
                released = true
                releaseFailure = failure
            }
            throw failure
        }
        lock.withLock { released = true }
    }

    private func terminateForCleanup() {
        lock.withLock { forcedTermination = true }
        if process.isRunning {
            process.terminate()
        }
        try? output.close()
        lines.cancel()
    }

    private static func monitorTerminal(
        process: Process,
        lines: SSHLeaseLineReader,
        terminationIntent: KwtSSHLeaseTerminationIntent
    ) async -> KwtSSHLeaseError? {
        do {
            while let line = try await lines.next() {
                guard let failure = KwtSSHLeaseClient.decodeFailure(line) else {
                    return .malformedEvent
                }
                return failure
            }
        } catch {
            if Task.isCancelled {
                return nil
            }
            return .malformedEvent
        }
        while process.isRunning, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled else {
            return nil
        }
        if process.terminationStatus == 0 {
            return terminationIntent.isReleasing
                ? nil
                : .operationFailed(
                    code: "ssh_connection_changed",
                    message: "The SSH lease helper exited unexpectedly.",
                    retryable: false
                )
        }
        return .commandFailed(status: process.terminationStatus)
    }
}

private final class KwtSSHLeaseTerminationIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var releasing = false

    var isReleasing: Bool {
        lock.withLock { releasing }
    }

    func beginRelease() {
        lock.withLock { releasing = true }
    }

    func cancelRelease() {
        lock.withLock { releasing = false }
    }
}

/// Hands newline-delimited helper output to one async consumer in order.
private final class SSHLeaseLineChannel: @unchecked Sendable {
    enum Item: Sendable {
        case line(String)
        case end
        case failed
        case canceled
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<Item, Never>)?

    func send(_ item: Item) {
        let continuation: CheckedContinuation<Item, Never>? = lock.withLock {
            if let waiter {
                self.waiter = nil
                return waiter.continuation
            }
            items.append(item)
            return nil
        }
        continuation?.resume(returning: item)
    }

    func next() async -> Item {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: Item? = lock.withLock {
                    if !items.isEmpty {
                        return items.removeFirst()
                    }
                    if Task.isCancelled {
                        return .canceled
                    }
                    precondition(waiter == nil)
                    waiter = (id, continuation)
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        } onCancel: {
            cancelWaiter(id: id)
        }
    }

    private func cancelWaiter(id: UUID) {
        let continuation: CheckedContinuation<Item, Never>? = lock.withLock {
            guard waiter?.id == id else { return nil }
            let continuation = waiter?.continuation
            waiter = nil
            return continuation
        }
        continuation?.resume(returning: .canceled)
    }
}

/// Reads helper stdout through a dispatch I/O channel. A lease held for a long
/// presentation therefore occupies neither the cooperative executor nor a
/// process-lifetime thread. The channel owns a duplicate descriptor and stops
/// at EOF, which arrives once the helper exits.
private final class SSHLeaseLineReader: @unchecked Sendable {
    private let channel: SSHLeaseLineChannel
    private let cancellation = SSHLeaseLineReaderCancellation()
    private let io: DispatchIO?

    init(output: FileHandle) {
        let channel = SSHLeaseLineChannel()
        self.channel = channel
        let descriptor = dup(output.fileDescriptor)
        guard descriptor >= 0 else {
            io = nil
            channel.send(.failed)
            return
        }
        let queue = DispatchQueue(
            label: "ghosthub.kwt-ssh-lease.reader",
            qos: .utility
        )
        let io = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: queue
        ) { _ in
            close(descriptor)
        }
        self.io = io
        let state = SSHLeaseLineDispatchState(channel: channel)
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: Int.max, queue: queue) {
            done, data, error in
            state.receive(done: done, data: data, error: error)
        }
    }

    func next() async throws -> String? {
        switch await channel.next() {
        case let .line(line):
            line
        case .end:
            nil
        case .failed:
            throw KwtSSHLeaseError.malformedEvent
        case .canceled:
            throw CancellationError()
        }
    }

    func cancel() {
        guard cancellation.cancel() else { return }
        channel.send(.canceled)
        io?.close(flags: .stop)
    }

    deinit {
        cancel()
    }

}

private final class SSHLeaseLineDispatchState: @unchecked Sendable {
    private let channel: SSHLeaseLineChannel
    private var pending = Data()
    private var finished = false

    init(channel: SSHLeaseLineChannel) {
        self.channel = channel
    }

    func receive(done: Bool, data: DispatchData?, error: Int32) {
        guard !finished else { return }
        if error != 0 {
            finished = true
            channel.send(.failed)
            return
        }
        if let data, !data.isEmpty {
            pending.append(contentsOf: data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let text = String(data: line, encoding: .utf8) else {
                    finished = true
                    channel.send(.failed)
                    return
                }
                channel.send(.line(text))
            }
        }
        guard done else { return }
        finished = true
        if !pending.isEmpty {
            guard let text = String(data: pending, encoding: .utf8) else {
                channel.send(.failed)
                return
            }
            channel.send(.line(text))
        }
        channel.send(.end)
    }
}

private final class SSHLeaseLineReaderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
    }
}

private final class SSHLeaseInactivityWatchdog: @unchecked Sendable {
    private let process: Process
    private let output: FileHandle
    private let lines: SSHLeaseLineReader
    private let timeout: Duration
    private let lock = NSLock()
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var expired = false

    var isExpired: Bool {
        lock.withLock { expired }
    }

    init(
        process: Process,
        output: FileHandle,
        lines: SSHLeaseLineReader,
        timeout: Duration
    ) {
        self.process = process
        self.output = output
        self.lines = lines
        self.timeout = timeout
    }

    func arm() {
        let token = lock.withLock {
            generation = UUID()
            task?.cancel()
            return generation
        }
        let scheduled = Task { [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .zero)
            guard !Task.isCancelled else { return }
            self?.expire(token)
        }
        lock.withLock {
            guard generation == token, !expired else {
                scheduled.cancel()
                return
            }
            task = scheduled
        }
    }

    func suspend() {
        lock.withLock {
            generation = UUID()
            task?.cancel()
            task = nil
        }
    }

    func cancel() {
        suspend()
    }

    private func expire(_ token: UUID) {
        let shouldExpire = lock.withLock {
            guard generation == token, !expired else { return false }
            expired = true
            task = nil
            return true
        }
        guard shouldExpire else { return }
        if process.isRunning {
            process.terminate()
        }
        try? output.close()
        lines.cancel()
    }
}

struct KwtSSHLeaseClient: Sendable {
    typealias PromptHandler = @Sendable (KwtSSHLeasePrompt) async throws -> String

    private let binaryPath: String?
    private let environment: [String: String]?
    private let inactivityTimeout: Duration

    init(
        binaryPath: String? = KwtBinaryLocator.bundledPath(),
        environment: [String: String]? = nil,
        inactivityTimeout: Duration = .seconds(30)
    ) {
        self.binaryPath = binaryPath
        self.environment = environment
            ?? KwtSSHRuntimeEnvironment.resolved()
        self.inactivityTimeout = inactivityTimeout
    }

    func acquire(
        route: KwtSSHRouteSnapshot,
        hostKeyPolicy: KwtSSHHostKeyPolicy = .review,
        prompt: @escaping PromptHandler
    ) async throws -> KwtSSHLease {
        guard binaryPath != "" else {
            throw KwtSSHLeaseError.helperUnavailable
        }
        let executable = binaryPath ?? "/usr/bin/env"
        var arguments = binaryPath == nil ? ["kwt"] : []
        arguments.append(contentsOf: [
            "ssh", "lease", "--json",
            "--route-identity", route.routeIdentity,
            "--projection-policy", route.projectionPolicy,
            "--host-key-policy", hostKeyPolicy.rawValue,
        ])
        if let user = route.logicalTarget.user {
            arguments.append(contentsOf: ["--user", user])
        }
        if let port = route.logicalTarget.port {
            arguments.append(contentsOf: ["--port", String(port)])
        }
        arguments.append(route.logicalTarget.hostname)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw KwtSSHLeaseError.launchFailed
        }
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        let input = inputPipe.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        let output = outputPipe.fileHandleForReading
        let lines = SSHLeaseLineReader(output: output)
        let watchdog = SSHLeaseInactivityWatchdog(
            process: process,
            output: output,
            lines: lines,
            timeout: inactivityTimeout
        )
        watchdog.arm()

        do {
            var operationID: String?
            var sequence: UInt64 = 0
            while let line = try await lines.next() {
                guard let data = line.data(using: .utf8) else {
                    throw KwtSSHLeaseError.malformedEvent
                }
                let event: OperationEvent
                do {
                    event = try JSONDecoder().decode(
                        OperationEvent.self,
                        from: data
                    )
                } catch {
                    throw KwtSSHLeaseError.malformedEvent
                }
                if operationID == nil {
                    operationID = event.operationID
                }
                guard !event.operationID.isEmpty,
                      event.operationID == operationID,
                      event.sequence == sequence + 1
                else {
                    throw KwtSSHLeaseError.malformedEvent
                }
                watchdog.arm()
                sequence = event.sequence
                switch event.kind {
                case .progress, .warning:
                    break
                case .prompt:
                    guard let eventPrompt = event.prompt,
                          Self.isValid(eventPrompt, for: route)
                    else {
                        throw KwtSSHLeaseError.malformedEvent
                    }
                    watchdog.suspend()
                    let value = try await prompt(eventPrompt)
                    var encoded = try JSONEncoder().encode(
                        KwtSSHLeasePromptResponse(
                            promptID: eventPrompt.id,
                            value: value
                        )
                    )
                    encoded.append(0x0A)
                    try input.write(contentsOf: encoded)
                    watchdog.arm()
                case .complete:
                    if let failure = event.failure {
                        if failure.code == "ssh_configuration_changed" {
                            throw KwtSSHLeaseError.routeChanged
                        }
                        throw KwtSSHLeaseError.operationFailed(
                            code: failure.code,
                            message: failure.message,
                            retryable: failure.retryable
                        )
                    }
                    guard let result = event.result,
                          !result.leaseID.isEmpty,
                          result.routeIdentity == route.routeIdentity,
                          Self.isValidLeaseArguments(result.arguments)
                    else {
                        throw KwtSSHLeaseError.malformedEvent
                    }
                    guard result.mode == .multiplexed else {
                        throw KwtSSHLeaseError.persistentUnsupported
                    }
                    watchdog.cancel()
                    return KwtSSHLease(
                        result: result,
                        process: process,
                        input: input,
                        output: output,
                        lines: lines
                    )
                }
            }
            if watchdog.isExpired {
                throw KwtSSHLeaseError.acquisitionTimedOut
            }
            if process.isRunning {
                process.terminate()
                throw KwtSSHLeaseError.commandFailed(status: -1)
            }
            throw KwtSSHLeaseError.commandFailed(
                status: process.terminationStatus
            )
        } catch {
            let failure = watchdog.isExpired
                ? KwtSSHLeaseError.acquisitionTimedOut
                : error
            watchdog.cancel()
            try? input.close()
            if process.isRunning {
                process.terminate()
            }
            try? output.close()
            lines.cancel()
            throw failure
        }
    }

    private enum EventKind: String, Decodable {
        case progress
        case warning
        case prompt
        case complete
    }

    private struct Failure: Decodable {
        let code: String
        let message: String
        let retryable: Bool
    }

    private struct ErrorEnvelope: Decodable {
        let error: Failure
    }

    fileprivate static func decodeFailure(_ line: String) -> KwtSSHLeaseError? {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                  ErrorEnvelope.self,
                  from: data
              )
        else { return nil }
        return .operationFailed(
            code: envelope.error.code,
            message: envelope.error.message,
            retryable: envelope.error.retryable
        )
    }

    private struct OperationEvent: Decodable {
        let operationID: String
        let sequence: UInt64
        let kind: EventKind
        let message: String?
        let prompt: KwtSSHLeasePrompt?
        let result: KwtSSHLeaseResult?
        let failure: Failure?

        private enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case sequence
            case kind
            case message
            case prompt
            case result
            case failure
        }
    }

    private static func isValidLeaseArguments(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty, arguments.count.isMultiple(of: 2) else {
            return false
        }
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value = arguments[index + 1]
            guard !value.isEmpty,
                  value.rangeOfCharacter(from: .newlines) == nil,
                  !value.contains("\0")
            else {
                return false
            }
            switch flag {
            case "-F", "-S":
                break
            case "-o":
                guard let separator = value.firstIndex(of: "="),
                      separator != value.startIndex,
                      value.index(after: separator) != value.endIndex
                else {
                    return false
                }
                let name = String(value[..<separator])
                let option = String(value[value.index(after: separator)...])
                switch name {
                case "ForwardAgent", "SendEnv", "EscapeChar":
                    break
                case "ControlMaster", "ControlPersist":
                    guard option == "no" else { return false }
                case "BatchMode":
                    guard option == "yes" else { return false }
                case "ProxyCommand":
                    guard option == "/usr/bin/false" else { return false }
                default:
                    return false
                }
            default:
                return false
            }
            index += 2
        }
        return true
    }

    private static func hasExpectedSensitivity(
        _ prompt: KwtSSHLeasePrompt
    ) -> Bool {
        switch prompt.kind {
        case .authentication:
            prompt.sensitive
        case .hostKey:
            !prompt.sensitive
        }
    }

    private static func hasExpectedHostKeyReview(
        _ prompt: KwtSSHLeasePrompt
    ) -> Bool {
        switch prompt.kind {
        case .authentication:
            return prompt.details.hostKey == nil
        case .hostKey:
            guard let hostKey = prompt.details.hostKey else { return false }
            return !hostKey.host.isEmpty
                && !hostKey.algorithm.isEmpty
                && !hostKey.fingerprint.isEmpty
        }
    }

    private static func isValid(
        _ prompt: KwtSSHLeasePrompt,
        for route: KwtSSHRouteSnapshot
    ) -> Bool {
        let details = prompt.details
        guard !prompt.id.isEmpty,
              isRFC3339(prompt.deadline),
              details.hopCount == route.targets.count,
              details.hopIndex >= 0,
              details.hopIndex < route.targets.count,
              hasExpectedSensitivity(prompt),
              hasExpectedHostKeyReview(prompt) else {
            return false
        }
        let target = route.targets[details.hopIndex]
        return details.logicalTarget == target.logicalTarget
            && details.effectiveTarget == target.effectiveTarget
            && details.displayTarget == target.displayTarget
    }

    private static func isRFC3339(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil {
            return true
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}
