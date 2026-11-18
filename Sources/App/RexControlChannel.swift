import Foundation
import GhosthubBackendTerminal

enum RexControlChannelExit: Equatable {
    /// The Rex session ended.
    case ended
    /// kwt stopped for another reason, with what it wrote to stderr.
    case failed(String)
}

@MainActor
protocol RexControlChannelling: AnyObject {
    var onView: ((RexControlView) -> Void)? { get set }
    var onExit: ((RexControlChannelExit) -> Void)? { get set }
    /// Sends a layout request and returns when kwt answers it, with the
    /// session's revision after it when Rex reports one.
    @discardableResult
    func send(method: String, params: [String: any Sendable]) async throws -> Int?
    func stop()
}

/// Starts `kwt rex control` from its `/bin/sh -c` command.
typealias RexControlChannelFactory = @MainActor (String) throws -> any RexControlChannelling

/// One running `kwt rex control WINDOW_ID`. Views and replies arrive on the
/// main queue in the order kwt wrote them.
@MainActor
final class RexControlChannel: RexControlChannelling {
    var onView: ((RexControlView) -> Void)?
    var onExit: ((RexControlChannelExit) -> Void)?

    private let command: String
    private let accountShell: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var lineBuffer = Data()
    /// Login files can print before kwt starts; its messages begin after
    /// `RexInventory.controlMarker`.
    private var sawMarker = false
    private var errorText = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Int?, any Error>] = [:]
    private var outputClosed = false
    private var errorsClosed = false
    private var exited = false
    private var ended = false
    private var finished = false

    /// `command` runs under `/bin/sh -c`, such as
    /// `BackendTerminalAttachmentInfo.controlCommand`, which starts
    /// `$SHELL` as a login shell. `SHELL` is the account's shell, as for
    /// Rex discovery, rather than the one Ghosthub inherited.
    init(command: String, accountShell: String = AccountCommandRunner.loginShell()) {
        self.command = command
        self.accountShell = accountShell
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["SHELL": accountShell]) { _, account in account }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A request written after kwt exits fails instead of killing Ghosthub.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receiveError(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.exited = true
                    self?.finishIfDone()
                }
            }
        }
        try process.run()
    }

    static func started(command: String) throws -> any RexControlChannelling {
        let channel = RexControlChannel(command: command)
        try channel.start()
        return channel
    }

    @discardableResult
    func send(method: String, params: [String: any Sendable]) async throws -> Int? {
        guard !finished else { throw CancellationError() }
        let id = nextID
        nextID += 1
        var line = try JSONSerialization.data(withJSONObject: [
            "id": id, "method": method, "params": params,
        ])
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.fileHandleForWriting.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    /// Stops kwt without reporting an exit. Requests still waiting throw
    /// `CancellationError`.
    func stop() {
        guard !finished else { return }
        finished = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        cancelPending()
    }

    private func receive(_ data: Data) {
        guard !finished else { return }
        guard !data.isEmpty else {
            outputClosed = true
            finishIfDone()
            return
        }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex ..< newline]
            lineBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard sawMarker else {
                sawMarker = line.elementsEqual(RexInventory.controlMarker.utf8)
                continue
            }
            guard let message = try? RexControlMessage.decode(line: Data(line)) else {
                fail("Cannot read the Rex window layout.")
                return
            }
            handle(message)
            if finished {
                return
            }
        }
    }

    private func receiveError(_ data: Data) {
        guard !data.isEmpty else {
            errorsClosed = true
            finishIfDone()
            return
        }
        if errorText.count < 4096 {
            errorText.append(data.prefix(4096 - errorText.count))
        }
    }

    private func handle(_ message: RexControlMessage) {
        switch message {
        case let .view(view):
            onView?(view)
        case let .reply(id, revision, error):
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: revision)
            }
        case .ended:
            ended = true
        }
    }

    private func finishIfDone() {
        // Every pipe is read to its end first, so the last view and kwt's
        // last message arrive before the exit is reported.
        guard outputClosed, errorsClosed, exited, !finished else { return }
        if ended {
            finished = true
            cancelPending()
            onExit?(.ended)
        } else {
            let message = String(decoding: errorText, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fail(message.isEmpty ? "The Rex connection closed." : message)
        }
    }

    private func fail(_ message: String) {
        stop()
        onExit?(.failed(message))
    }

    private func cancelPending() {
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
    }
}
