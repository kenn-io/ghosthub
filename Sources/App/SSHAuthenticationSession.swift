import Darwin
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

enum SSHAuthenticationSessionState: Equatable, Sendable {
    case starting
    case prompt(SSHAuthenticationPrompt)
    case verifying
    case connected
    case failed(String)
}

private struct SSHAuthenticationPreparation: Sendable {
    let temporaryState: SSHAuthenticationTemporaryState
    let controlPath: String
    let hostKeyArguments: [String]

    static func prepare(for host: SSHHostInfo) -> SSHAuthenticationPreparationResult {
        do {
            let temporaryState = try SSHAuthenticationTemporaryState.create()
            do {
                try Task.checkCancellation()
                guard let controlPath = SSHConnectionPool.controlPath(
                    for: host
                ) else {
                    throw SSHAuthenticationError.stateUnavailable
                }
                try Task.checkCancellation()
                let hostKeyArguments =
                    SSHConfigurationResolver.interactiveHostKeyArguments(
                        for: host
                    )
                try Task.checkCancellation()
                return .success(SSHAuthenticationPreparation(
                    temporaryState: temporaryState,
                    controlPath: controlPath,
                    hostKeyArguments: hostKeyArguments
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

private enum SSHAuthenticationPreparationResult: Sendable {
    case success(SSHAuthenticationPreparation)
    case failure(String)
    case cancelled
}

@MainActor
final class SSHAuthenticationSession: ObservableObject {
    @Published private(set) var state: SSHAuthenticationSessionState = .starting

    let host: SSHHostInfo
    private var process: Process?
    private var standardError: Pipe?
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration = UUID()
    private var monitorTask: Task<Void, Never>?
    private var temporaryState: SSHAuthenticationTemporaryState?
    private var lastPromptID: String?
    private(set) var controlPath: String?

    init(host: SSHHostInfo) {
        self.host = host
        start()
    }

    func submit(_ response: String) {
        guard case .prompt = state,
              let responseFIFO = temporaryState?.responseFIFO
        else { return }
        state = .verifying
        Task { [weak self] in
            let wroteResponse = await Task.detached {
                Self.writeResponse(response, toFIFO: responseFIFO)
            }.value
            guard let self, !wroteResponse else { return }
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
        guard let controlPath, controlPath != currentControlPath else { return }
        stop()
        state = .starting
        start()
    }

    private func start() {
        let generation = UUID()
        preparationGeneration = generation
        let host = host
        let resolver = Task.detached(priority: .userInitiated) {
            SSHAuthenticationPreparation.prepare(for: host)
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
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = SSHConnectionPool.authenticationArguments(
                for: host,
                controlPath: preparation.controlPath,
                hostKeyArguments: preparation.hostKeyArguments
            )
            process.environment = ProcessInfo.processInfo.environment.merging([
                "SSH_ASKPASS": preparation.temporaryState.helper.path,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "ghosthub",
                "GHOSTHUB_SSH_PROMPT_PATH": preparation.temporaryState.prompt.path,
                "GHOSTHUB_SSH_RESPONSE_FIFO":
                    preparation.temporaryState.responseFIFO.path,
            ]) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = standardError
            try process.run()

            temporaryState = preparation.temporaryState
            controlPath = preparation.controlPath
            self.process = process
            self.standardError = standardError
            lastPromptID = nil
            monitorTask = Task { [weak self] in
                await self?.monitor()
            }
        } catch {
            preparation.temporaryState.remove()
            state = .failed(error.localizedDescription)
        }
    }

    private func monitor() async {
        while !Task.isCancelled {
            if let prompt = currentPrompt(), prompt.id != lastPromptID {
                lastPromptID = prompt.id
                state = .prompt(prompt)
            }

            if process?.isRunning != true {
                let message = state == .connected
                    ? "The SSH connection ended. Try again."
                    : connectionFailureMessage()
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

    private func connectionFailureMessage() -> String {
        let data = standardError?.fileHandleForReading.readDataToEndOfFile()
            ?? Data()
        let diagnostic = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let diagnostic, !diagnostic.isEmpty else {
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
        process = nil
        standardError = nil
        temporaryState?.remove()
        temporaryState = nil
        lastPromptID = nil
        controlPath = nil
    }

    deinit {
        preparationTask?.cancel()
        monitorTask?.cancel()
        if process?.isRunning == true {
            process?.terminate()
        }
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
}

@MainActor
final class SSHAuthenticationCoordinator {
    private var sessions: [UUID: SSHAuthenticationSession] = [:]

    func session(
        id: UUID,
        host: SSHHostInfo
    ) -> SSHAuthenticationSession {
        if let existing = sessions[id], existing.host == host {
            return existing
        }
        sessions.removeValue(forKey: id)?.cancel()
        let session = SSHAuthenticationSession(host: host)
        sessions[id] = session
        return session
    }

    func cancel(id: UUID) {
        sessions.removeValue(forKey: id)?.cancel()
    }

    func reconcileIdentity(
        host: SSHHostInfo,
        controlPath: String
    ) {
        for session in sessions.values where session.host == host {
            session.restartIfIdentityChanged(to: controlPath)
        }
    }

    func markConnected(
        host: SSHHostInfo,
        controlPath: String
    ) {
        for session in sessions.values where session.host == host {
            if session.controlPath == controlPath {
                session.markConnected()
            }
        }
    }

    func shutdown() {
        sessions.values.forEach { $0.cancel() }
        sessions.removeAll()
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
