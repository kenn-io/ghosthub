import GhosthubTransport
import Darwin
import Dispatch
import Foundation
import GhosthubTmux

struct SSHAuthenticationPrompt: Equatable, Sendable {
    let id: String
    let message: String

    static func parse(_ data: Data) -> SSHAuthenticationPrompt? {
        guard let value = String(data: data, encoding: .utf8),
              let separator = value.firstIndex(of: "\n")
        else { return nil }
        let id = String(value[..<separator])
        let message = String(value[value.index(after: separator)...])
        guard !id.isEmpty, !message.isEmpty else { return nil }
        return SSHAuthenticationPrompt(id: id, message: message)
    }
}

final class SSHDiagnosticBuffer: @unchecked Sendable {
    static let defaultMaximumBytes = 64 * 1024

    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()

    init(maximumBytes: Int = defaultMaximumBytes) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) {
        guard maximumBytes > 0, !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if chunk.count >= maximumBytes {
            data = Data(chunk.suffix(maximumBytes))
            return
        }
        let overflow = data.count + chunk.count - maximumBytes
        if overflow > 0 {
            data.removeFirst(overflow)
        }
        data.append(chunk)
    }

    func text() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}

private final class SSHDiagnosticCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuations = continuations
        self.continuations.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }
}

final class SSHDiagnosticDrain: @unchecked Sendable {
    private let buffer: SSHDiagnosticBuffer
    private let source: DispatchSourceRead
    private let completion: SSHDiagnosticCompletion

    private init(
        buffer: SSHDiagnosticBuffer,
        source: DispatchSourceRead,
        completion: SSHDiagnosticCompletion
    ) {
        self.buffer = buffer
        self.source = source
        self.completion = completion
    }

    static func start(
        pipe: Pipe,
        maximumBytes: Int = SSHDiagnosticBuffer.defaultMaximumBytes
    ) -> SSHDiagnosticDrain {
        let buffer = SSHDiagnosticBuffer(maximumBytes: maximumBytes)
        let completion = SSHDiagnosticCompletion()
        let handle = pipe.fileHandleForReading
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "io.kenn.ghosthub.ssh-diagnostics")
        )
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            var remainingReads = 64
            while remainingReads > 0, !source.isCancelled {
                remainingReads -= 1
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(
                        descriptor,
                        buffer.baseAddress,
                        buffer.count
                    )
                }
                if count > 0 {
                    buffer.append(Data(bytes.prefix(Int(count))))
                } else if count == 0 {
                    source.cancel()
                    return
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else if errno != EINTR {
                    source.cancel()
                    return
                }
            }
        }
        source.setCancelHandler {
            try? handle.close()
            completion.finish()
        }
        source.resume()
        return SSHDiagnosticDrain(
            buffer: buffer,
            source: source,
            completion: completion
        )
    }

    func finish() async -> String {
        await completion.wait()
        return buffer.text()
    }

    var bufferedText: String {
        buffer.text()
    }

    func finish(after timeout: Duration) async -> String {
        let source = source
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            source.cancel()
        }
        await completion.wait()
        timeoutTask.cancel()
        return buffer.text()
    }

    func cancel() {
        source.cancel()
    }
}

enum SSHAuthenticationSessionState: Equatable, Sendable {
    case starting
    case prompt(SSHAuthenticationPrompt)
    case verifying
    case connected
    case configurationChanged
    case failed(String)
}

struct SSHAuthenticationPreparation: Sendable {
    let target: SSHAuthenticationTarget
    let displayHost: SSHHostInfo
    let temporaryState: SSHAuthenticationTemporaryState
    let controlPath: String
    let hostKeyArguments: [String]
    let proxyArguments: [String]
    let configurationArguments: [String]

    static func prepare(
        for target: SSHAuthenticationTarget,
        controlPath: String?,
        configurationSnapshot: SSHConnectionConfigurationSnapshot
    ) -> SSHAuthenticationPreparationResult {
        let configurationProvider = configurationSnapshot.configurationProvider
        return prepare(
            for: target,
            controlPath: controlPath,
            identityProvider: {
                SSHConnectionPool.authenticationIdentity(
                    for: $0,
                    configurationSnapshot: configurationSnapshot
                )
            },
            hostKeyArgumentsProvider: {
                SSHConfigurationResolver.authenticationHostKeyArguments(
                    for: $0,
                    configurationProvider: configurationProvider
                )
            },
            proxyArgumentsProvider: {
                SSHConnectionPool.proxyArguments(
                    for: $0,
                    configurationProvider: configurationProvider
                )
            },
            configurationArgumentsProvider: {
                SSHConfigurationResolver.snapshotAuthenticationArguments(
                    for: $0,
                    configurationProvider: configurationProvider
                )
            }
        )
    }

    static func prepare(
        for target: SSHAuthenticationTarget,
        controlPath: String?,
        identityProvider: @Sendable (SSHAuthenticationTarget) ->
            SSHAuthenticationIdentity? = {
                SSHConnectionPool.authenticationIdentity(for: $0)
            },
        hostKeyArgumentsProvider: @Sendable (SSHHostInfo) -> [String] = {
            SSHConfigurationResolver.authenticationHostKeyArguments(for: $0)
        },
        proxyArgumentsProvider: @Sendable (SSHAuthenticationTarget) -> [String] = {
            SSHConnectionPool.proxyArguments(for: $0)
        },
        configurationArgumentsProvider: @Sendable (SSHHostInfo) -> [String] = {
            _ in tmuxSSHConnectionArguments()
        }
    ) -> SSHAuthenticationPreparationResult {
        do {
            let temporaryState = try SSHAuthenticationTemporaryState.create()
            do {
                try Task.checkCancellation()
                guard let controlPath = controlPath
                    ?? identityProvider(target)?.controlPath else {
                    throw SSHAuthenticationError.stateUnavailable
                }
                try Task.checkCancellation()
                let hostKeyArguments = hostKeyArgumentsProvider(target.host)
                try Task.checkCancellation()
                let proxyArguments = proxyArgumentsProvider(target)
                try Task.checkCancellation()
                let configurationArguments =
                    configurationArgumentsProvider(target.host)
                try Task.checkCancellation()
                guard let launchIdentity = identityProvider(target),
                      launchIdentity.controlPath == controlPath else {
                    temporaryState.remove()
                    return .configurationChanged
                }
                return .success(SSHAuthenticationPreparation(
                    target: target,
                    displayHost: launchIdentity.displayHost,
                    temporaryState: temporaryState,
                    controlPath: controlPath,
                    hostKeyArguments: hostKeyArguments,
                    proxyArguments: proxyArguments,
                    configurationArguments: configurationArguments
                ))
            } catch {
                temporaryState.remove()
                throw error
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

struct SSHAuthenticationProcessInvocation: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
}

enum SSHAuthenticationPreparationResult: Sendable {
    case success(SSHAuthenticationPreparation)
    case configurationChanged
    case failure(String)
    case cancelled
}

@MainActor
final class SSHAuthenticationSession: ObservableObject {
    @Published private(set) var state: SSHAuthenticationSessionState = .starting
    @Published private(set) var displayHost: SSHHostInfo?

    let target: SSHAuthenticationTarget
    let requestedControlPath: String?
    var host: SSHHostInfo { target.host }
    private var process: Process?
    private var standardError: Pipe?
    private var diagnosticDrain: SSHDiagnosticDrain?
    private var watchdogPipe: Pipe?
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration = UUID()
    private var monitorTask: Task<Void, Never>?
    private var temporaryState: SSHAuthenticationTemporaryState?
    private var lastPromptID: String?
    private(set) var controlPath: String?

    init(host: SSHHostInfo) {
        target = SSHAuthenticationTarget(
            host: host,
            precedingProxyHops: []
        )
        requestedControlPath = nil
        start()
    }

    init(
        target: SSHAuthenticationTarget,
        controlPath: String? = nil
    ) {
        self.target = target
        requestedControlPath = controlPath
        start()
    }

    func submit(_ response: String) {
        guard case .prompt = state,
              let responseFIFO = temporaryState?.responseFIFO
        else { return }
        let generation = preparationGeneration
        state = .verifying
        Task { [weak self] in
            let wroteResponse = await Task.detached {
                Self.writeResponse(response, toFIFO: responseFIFO)
            }.value
            guard let self,
                  !wroteResponse,
                  preparationGeneration == generation
            else { return }
            state = .failed(
                "Ghosthub could not send the response to OpenSSH. Try again."
            )
        }
    }

    func retry() {
        stop()
        state = .starting
        start()
    }

    func cancel() {
        stop()
    }

    func markConnected() {
        state = .connected
        temporaryState?.remove()
        temporaryState = nil
    }

    func restartIfIdentityChanged(to currentControlPath: String) {
        guard requestedControlPath == nil,
              let controlPath,
              controlPath != currentControlPath else { return }
        stop()
        state = .starting
        start()
    }

    private func start() {
        let generation = UUID()
        preparationGeneration = generation
        let target = target
        let controlPath = requestedControlPath
        let resolver = Task.detached(priority: .userInitiated) {
            let configurationSnapshot =
                SSHConnectionPool.configurationSnapshot(for: target)
            return SSHAuthenticationPreparation.prepare(
                for: target,
                controlPath: controlPath,
                configurationSnapshot: configurationSnapshot
            )
        }
        preparationTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await resolver.value
            } onCancel: {
                resolver.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  preparationGeneration == generation
            else {
                if case let .success(preparation) = result {
                    preparation.temporaryState.remove()
                }
                return
            }
            preparationTask = nil
            switch result {
            case let .success(preparation):
                launch(preparation)
            case .configurationChanged:
                state = .configurationChanged
            case let .failure(message):
                state = .failed(message)
            case .cancelled:
                break
            }
        }
    }

    private func launch(_ preparation: SSHAuthenticationPreparation) {
        do {
            let process = Process()
            let standardError = Pipe()
            let watchdogPipe = Pipe()
            let sshArguments = SSHConnectionPool.authenticationArguments(
                for: preparation.target,
                controlPath: preparation.controlPath,
                hostKeyArguments: preparation.hostKeyArguments,
                proxyArguments: preparation.proxyArguments,
                configurationArguments: preparation.configurationArguments
            )
            let invocation = Self.processInvocation(
                sshArguments: sshArguments,
                accountShell: AccountCommandRunner.loginShell()
            )
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.environment = Self.processEnvironment(
                launcherEnvironment: ProcessInfo.processInfo.environment,
                askPassEnvironment: [
                    "SSH_ASKPASS": preparation.temporaryState.helper.path,
                    "SSH_ASKPASS_REQUIRE": "force",
                    "DISPLAY": "ghosthub",
                    "GHOSTHUB_SSH_PROMPT_PATH": preparation.temporaryState.prompt.path,
                    "GHOSTHUB_SSH_RESPONSE_FIFO":
                        preparation.temporaryState.responseFIFO.path,
                ]
            )
            process.standardInput = watchdogPipe.fileHandleForReading
            process.standardOutput = FileHandle.nullDevice
            process.standardError = standardError
            displayHost = preparation.displayHost
            try process.run()
            try? watchdogPipe.fileHandleForReading.close()
            try? standardError.fileHandleForWriting.close()

            let diagnosticDrain = SSHDiagnosticDrain.start(
                pipe: standardError
            )

            temporaryState = preparation.temporaryState
            controlPath = preparation.controlPath
            self.process = process
            self.standardError = standardError
            self.diagnosticDrain = diagnosticDrain
            self.watchdogPipe = watchdogPipe
            lastPromptID = nil
            monitorTask = Task { [weak self] in
                await self?.monitor()
            }
        } catch {
            preparation.temporaryState.remove()
            state = .failed(error.localizedDescription)
        }
    }

    nonisolated static func processEnvironment(
        launcherEnvironment: [String: String],
        askPassEnvironment: [String: String]
    ) -> [String: String] {
        AccountCommandRunner.sanitizedProcessEnvironment(launcherEnvironment)
            .merging(askPassEnvironment) { _, new in new }
    }

    private func monitor() async {
        while !Task.isCancelled {
            if let prompt = currentPrompt(), prompt.id != lastPromptID {
                lastPromptID = prompt.id
                state = .prompt(prompt)
            }

            if process?.isRunning != true {
                let diagnosticDrain = diagnosticDrain
                self.diagnosticDrain = nil
                let diagnostic = await diagnosticDrain?.finish(
                    after: .seconds(1)
                ) ?? ""
                guard !Task.isCancelled else { return }
                let message = state == .connected
                    ? "The SSH connection ended. Try again."
                    : connectionFailureMessage(diagnostic)
                state = .failed(message)
                temporaryState?.remove()
                temporaryState = nil
                process = nil
                return
            }

            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func currentPrompt() -> SSHAuthenticationPrompt? {
        guard let promptURL = temporaryState?.prompt,
              let data = try? Data(contentsOf: promptURL)
        else { return nil }
        return SSHAuthenticationPrompt.parse(data)
    }

    private func connectionFailureMessage(_ output: String) -> String {
        let diagnostic = output.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !diagnostic.isEmpty else {
            return "OpenSSH could not authenticate this connection."
        }
        return diagnostic
    }

    private func stop() {
        preparationGeneration = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        if case .prompt = state,
           let responseFIFO = temporaryState?.responseFIFO {
            _ = Self.writeResponse("", toFIFO: responseFIFO)
        }
        if process?.isRunning == true {
            process?.terminate()
        }
        try? watchdogPipe?.fileHandleForWriting.close()
        diagnosticDrain?.cancel()
        process = nil
        standardError = nil
        diagnosticDrain = nil
        watchdogPipe = nil
        temporaryState?.remove()
        temporaryState = nil
        lastPromptID = nil
        controlPath = nil
        displayHost = nil
    }

    deinit {
        preparationTask?.cancel()
        monitorTask?.cancel()
        if process?.isRunning == true {
            process?.terminate()
        }
        try? watchdogPipe?.fileHandleForWriting.close()
        diagnosticDrain?.cancel()
        temporaryState?.remove()
    }

    nonisolated static func writeResponse(
        _ response: String,
        toFIFO fifo: URL
    ) -> Bool {
        let data = Data((response + "\n").utf8)
        for _ in 0 ..< 20 {
            let descriptor = Darwin.open(
                fifo.path,
                O_WRONLY | O_NONBLOCK
            )
            if descriptor >= 0 {
                defer { Darwin.close(descriptor) }
                return data.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        return false
                    }
                    return Darwin.write(
                        descriptor,
                        baseAddress,
                        buffer.count
                    ) == buffer.count
                }
            }
            usleep(50_000)
        }
        return false
    }

    nonisolated static func processInvocation(
        sshArguments: [String],
        accountShell: String,
        sshExecutable: String = "/usr/bin/ssh"
    ) -> SSHAuthenticationProcessInvocation {
        let arguments = [
            "/bin/sh", "-c", watchdogScript,
            "ghosthub-ssh-watchdog", sshExecutable,
        ] + sshArguments
        let command = arguments
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        return SSHAuthenticationProcessInvocation(
            executable: URL(fileURLWithPath: accountShell),
            arguments: ["-lc", accountShellCommand(command)]
        )
    }

    nonisolated static let watchdogScript = """
    set -u
    exec 3<&0
    "$@" &
    ssh_pid=$!
    cleanup() {
        /bin/kill -TERM "$ssh_pid" 2>/dev/null || true
    }
    trap cleanup HUP INT TERM EXIT
    (
        while IFS= read -r ghosthub_watchdog_input <&3; do :; done
        /bin/kill -TERM "$ssh_pid" 2>/dev/null || true
    ) &
    watchdog_pid=$!
    exec 3<&-
    wait "$ssh_pid"
    status=$?
    /bin/kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    trap - HUP INT TERM EXIT
    exit "$status"
    """
}

@MainActor
final class SSHAuthenticationCoordinator {
    private struct Owner: Hashable {
        let scopeID: UUID
        let presentationID: UUID
    }

    private struct Entry {
        let session: SSHAuthenticationSession
        var owners: Set<Owner>
    }

    private var entries: [Entry] = []
    private var sessionIDsByOwner: [Owner: ObjectIdentifier] = [:]

    func session(
        scopeID: UUID,
        presentationID: UUID,
        host: SSHHostInfo
    ) -> SSHAuthenticationSession {
        session(
            scopeID: scopeID,
            presentationID: presentationID,
            target: SSHAuthenticationTarget(
                host: host,
                precedingProxyHops: []
            )
        )
    }

    func session(
        scopeID: UUID,
        presentationID: UUID,
        target: SSHAuthenticationTarget,
        controlPath: String? = nil
    ) -> SSHAuthenticationSession {
        let owner = Owner(
            scopeID: scopeID,
            presentationID: presentationID
        )
        if let sessionID = sessionIDsByOwner[owner],
           let entry = entries.first(where: {
               ObjectIdentifier($0.session) == sessionID
           }),
           entry.session.target == target,
           entry.session.requestedControlPath == controlPath {
            return entry.session
        }
        release(owner)

        if let index = entries.firstIndex(where: {
            $0.session.target == target
                && $0.session.requestedControlPath == controlPath
        }) {
            entries[index].owners.insert(owner)
            let session = entries[index].session
            sessionIDsByOwner[owner] = ObjectIdentifier(session)
            return session
        }

        let session = SSHAuthenticationSession(
            target: target,
            controlPath: controlPath
        )
        entries.append(Entry(session: session, owners: [owner]))
        sessionIDsByOwner[owner] = ObjectIdentifier(session)
        return session
    }

    func cancel(scopeID: UUID, presentationID: UUID) {
        release(Owner(
            scopeID: scopeID,
            presentationID: presentationID
        ))
    }

    func cancelAll(scopeID: UUID) {
        let owners = sessionIDsByOwner.keys.filter {
            $0.scopeID == scopeID
        }
        owners.forEach(release)
    }

    func reconcileIdentity(
        target: SSHAuthenticationTarget,
        controlPath: String
    ) {
        for entry in entries where entry.session.target == target {
            entry.session.restartIfIdentityChanged(to: controlPath)
        }
    }

    func markConnected(
        target: SSHAuthenticationTarget,
        controlPath: String
    ) {
        for entry in entries where entry.session.target == target {
            let session = entry.session
            if session.controlPath == controlPath {
                session.markConnected()
            }
        }
    }

    func invalidate(
        target: SSHAuthenticationTarget,
        controlPath: String
    ) {
        let invalidSessionIDs: Set<ObjectIdentifier> = Set(
            entries.compactMap { entry in
                let session = entry.session
                guard session.target == target,
                      session.requestedControlPath == controlPath
                else { return nil }
                session.cancel()
                return ObjectIdentifier(session)
            }
        )
        guard !invalidSessionIDs.isEmpty else { return }
        entries.removeAll {
            invalidSessionIDs.contains(ObjectIdentifier($0.session))
        }
        sessionIDsByOwner = sessionIDsByOwner.filter {
            !invalidSessionIDs.contains($0.value)
        }
    }

    func requiresRecoveryRestart(
        target: SSHAuthenticationTarget,
        controlPath: String
    ) -> Bool {
        entries.contains { entry in
            entry.session.target == target
                && entry.session.requestedControlPath == controlPath
                && entry.session.state == .configurationChanged
        }
    }

    func shutdown() {
        entries.forEach { $0.session.cancel() }
        entries.removeAll()
        sessionIDsByOwner.removeAll()
    }

    private func release(_ owner: Owner) {
        guard let sessionID = sessionIDsByOwner.removeValue(forKey: owner),
              let index = entries.firstIndex(where: {
                  ObjectIdentifier($0.session) == sessionID
              })
        else { return }
        entries[index].owners.remove(owner)
        guard entries[index].owners.isEmpty,
              entries[index].session.state != .connected
        else { return }
        entries[index].session.cancel()
        entries.remove(at: index)
    }
}

private enum SSHAuthenticationError: LocalizedError {
    case stateUnavailable

    var errorDescription: String? {
        "Ghosthub could not prepare secure state for SSH authentication."
    }
}

struct SSHAuthenticationTemporaryState: Sendable {
    let directory: URL
    let helper: URL
    let prompt: URL
    let responseFIFO: URL

    static func create(
        fileManager: FileManager = .default
    ) throws -> SSHAuthenticationTemporaryState {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "ghosthub-ssh-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let state = SSHAuthenticationTemporaryState(
            directory: directory,
            helper: directory.appendingPathComponent("askpass"),
            prompt: directory.appendingPathComponent("prompt"),
            responseFIFO: directory.appendingPathComponent("response")
        )
        do {
            try Self.helperScript.write(
                to: state.helper,
                atomically: true,
                encoding: .utf8
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: state.helper.path
            )
            guard Darwin.mkfifo(state.responseFIFO.path, 0o600) == 0 else {
                throw SSHAuthenticationError.stateUnavailable
            }
            return state
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }

    static let helperScript = """
    #!/bin/sh
    set -eu
    prompt_path=${GHOSTHUB_SSH_PROMPT_PATH:?}
    response_fifo=${GHOSTHUB_SSH_RESPONSE_FIFO:?}
    temporary_prompt="${prompt_path}.tmp.$$"
    umask 077
    {
        printf '%s\\n' "$$"
        printf '%s' "${1-}"
    } > "$temporary_prompt"
    mv -f "$temporary_prompt" "$prompt_path"
    cat "$response_fifo"
    """
}
