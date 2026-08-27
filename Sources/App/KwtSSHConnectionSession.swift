import Foundation
import GhosthubSettings
import GhosthubTransport

@MainActor
final class KwtSSHConnectionSession: ObservableObject {
    @Published private(set) var state: SSHAuthenticationSessionState = .starting
    @Published private(set) var displayHost: SSHHostInfo?
    @Published private(set) var hostKeyConfirmation: SSHHostKeyConfirmation?

    var arguments: [String]? { connection?.arguments }

    private struct PendingPrompt {
        let acquisitionID: UUID
        let prompt: KwtSSHLeasePrompt
        let continuation: CheckedContinuation<String, Error>
        var deadlineTask: Task<Void, Never>?
    }

    private struct HandoffWaiter {
        let waitsAcrossRetries: Bool
        let continuation: CheckedContinuation<
            Result<KwtSSHConnection, Error>, Never
        >
    }

    private let request: KwtSSHDestinationRequest
    private let coordinator: KwtSSHAcquisitionCoordinator
    private let onPresentationRequired: @MainActor @Sendable () -> Void
    private var acquisitionID: UUID?
    private var acquisitionTask: Task<Void, Never>?
    private var terminalFailureTask: Task<Void, Never>?
    private var restartID: UUID?
    private var connection: KwtSSHConnection?
    private var pendingPrompt: PendingPrompt?
    private var requirementWaiters: [UUID: CheckedContinuation<
        Result<SSHHostTrustRequirement, HostProbeError>,
        Never
    >] = [:]
    private var handoffWaiters: [UUID: HandoffWaiter] = [:]
    private var connectionWasHandedOff = false
    private var connectionFailure: Error?

    var finalHost: SSHHostInfo { request.host }
    var isAwaitingPrompt: Bool { pendingPrompt != nil }
    var needsPresentation: Bool {
        if isAwaitingPrompt {
            return true
        }
        switch state {
        case .configurationChanged:
            return true
        case .failed:
            guard let connectionFailure else { return false }
            switch SSHConnectionFailure.classify(
                leaseError: connectionFailure
            ).kind {
            case .authenticationRequired, .hostKeyReviewRequired:
                return true
            case .transport, .hostKeyChanged, .configurationChanged:
                return false
            }
        case .starting, .prompt, .verifying, .connected:
            return false
        }
    }

    init(
        host: SSHHostInfo,
        destination: String,
        coordinator: KwtSSHAcquisitionCoordinator = .shared,
        onPresentationRequired: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        request = KwtSSHDestinationRequest(
            destination: destination,
            host: host
        )
        self.coordinator = coordinator
        self.onPresentationRequired = onPresentationRequired
        start()
    }

    func pendingRequirement()
        async -> Result<SSHHostTrustRequirement, HostProbeError> {
        if let result = currentRequirement {
            return result
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: Self.cancelledRequirement)
                } else {
                    requirementWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequirementWaiter(waiterID)
            }
        }
    }

    private func cancelRequirementWaiter(_ waiterID: UUID) {
        requirementWaiters.removeValue(forKey: waiterID)?
            .resume(returning: Self.cancelledRequirement)
    }

    private static let cancelledRequirement:
        Result<SSHHostTrustRequirement, HostProbeError> =
        .failure(.message("SSH connection cancelled."))

    func takeConnection(
        waitingAcrossRetries: Bool = false
    ) async throws -> KwtSSHConnection {
        guard !connectionWasHandedOff else {
            throw Self.connectionAlreadyHandedOff
        }
        let connection = try await waitForConnection(
            waitingAcrossRetries: waitingAcrossRetries
        )
        guard self.connection === connection else {
            throw Self.connectionAlreadyHandedOff
        }
        self.connection = nil
        connectionWasHandedOff = true
        return connection
    }

    func trust(_ confirmation: SSHHostKeyConfirmation) {
        guard confirmation == hostKeyConfirmation,
              pendingPrompt != nil
        else { return }
        hostKeyConfirmation = nil
        state = .verifying
        resumePrompt(with: "yes")
    }

    func submit(_ response: String) {
        guard case .prompt = state,
              pendingPrompt?.prompt.kind == .authentication
        else { return }
        state = .verifying
        resumePrompt(with: response)
    }

    func retry() {
        guard !connectionWasHandedOff else { return }
        let restartID = UUID()
        self.restartID = restartID
        let canceledID = cancelLocalAcquisition(
            retainingRetryWaiters: true
        )
        connection = nil
        connectionFailure = nil
        displayHost = nil
        hostKeyConfirmation = nil
        state = .starting
        let coordinator = coordinator
        let request = request
        Task { [weak self] in
            if let canceledID {
                await coordinator.cancel(
                    request: request,
                    subscriberID: canceledID
                )
            }
            guard let self, self.restartID == restartID else { return }
            self.restartID = nil
            start()
        }
    }

    func cancel() {
        restartID = nil
        cancelAcquisition()
        let connection = connection
        self.connection = nil
        if let connection {
            Task { try? await connection.release() }
        }
    }

    func release() async throws {
        restartID = nil
        cancelAcquisition()
        guard let connection else { return }
        self.connection = nil
        try await connection.release()
    }

    private var currentRequirement:
        Result<SSHHostTrustRequirement, HostProbeError>? {
        if let hostKeyConfirmation {
            return .success(.confirmation(hostKeyConfirmation))
        }
        switch state {
        case .starting, .verifying:
            return nil
        case .prompt:
            guard pendingPrompt != nil else { return nil }
            return .success(.authentication)
        case .connected:
            return .success(.none)
        case .configurationChanged:
            return .failure(.message(
                "The effective SSH configuration changed. Try again."
            ))
        case let .failed(message):
            return .failure(.message(message))
        }
    }

    private func start() {
        let request = request
        let coordinator = coordinator
        let acquisitionID = UUID()
        self.acquisitionID = acquisitionID
        connectionFailure = nil
        acquisitionTask = Task { [weak self] in
            do {
                let connection = try await coordinator.acquire(
                    request: request,
                    subscriberID: acquisitionID,
                    canPresentPrompts: true,
                    prompt: { [weak self] _, prompt in
                        guard let self else { throw CancellationError() }
                        return try await response(
                            to: prompt,
                            acquisitionID: acquisitionID
                        )
                    }
                )
                guard let self,
                      !Task.isCancelled,
                      self.acquisitionID == acquisitionID
                else {
                    try? await connection.release()
                    return
                }
                self.connection = connection
                connectionFailure = nil
                state = .connected
                self.acquisitionID = nil
                acquisitionTask = nil
                publishRequirement()
                publishConnection(.success(connection))
                observeTerminalFailure(
                    connection,
                    acquisitionID: acquisitionID
                )
            } catch {
                guard let self,
                      self.acquisitionID == acquisitionID
                else { return }
                self.acquisitionID = nil
                acquisitionTask = nil
                guard !(error is CancellationError && Task.isCancelled) else {
                    return
                }
                connectionFailure = error
                state = error as? KwtSSHLeaseError == .routeChanged
                    ? .configurationChanged
                    : .failed(error.localizedDescription)
                let retainsRetryWaiters = needsPresentation
                if retainsRetryWaiters {
                    onPresentationRequired()
                }
                publishRequirement()
                publishConnection(
                    .failure(error),
                    retainingRetryWaiters: retainsRetryWaiters
                )
            }
        }
    }

    private func response(
        to prompt: KwtSSHLeasePrompt,
        acquisitionID: UUID
    ) async throws -> String {
        guard self.acquisitionID == acquisitionID else {
            throw CancellationError()
        }
        guard pendingPrompt == nil else {
            throw KwtSSHLeaseError.malformedEvent
        }
        guard let deadline = Self.promptDeadline(prompt.deadline) else {
            throw KwtSSHLeaseError.malformedEvent
        }
        guard deadline > Date() else {
            throw Self.promptTimedOut
        }
        displayHost = Self.hostInfo(prompt.details.effectiveTarget)
        switch prompt.kind {
        case .hostKey:
            guard let review = prompt.details.hostKey else {
                throw KwtSSHLeaseError.malformedEvent
            }
            hostKeyConfirmation = SSHHostKeyConfirmation(
                destination: review.host,
                connectionDestination: request.destination,
                algorithm: review.algorithm,
                fingerprint: review.fingerprint,
                openSSHPrompt: prompt.message
            )
            state = .starting
        case .authentication:
            hostKeyConfirmation = nil
            state = .prompt(SSHAuthenticationPrompt(
                id: prompt.id,
                message: prompt.message
            ))
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingPrompt = PendingPrompt(
                acquisitionID: acquisitionID,
                prompt: prompt,
                continuation: continuation,
                deadlineTask: nil
            )
            pendingPrompt?.deadlineTask = Task { [weak self] in
                let delay = max(0, deadline.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.expirePrompt(
                    id: prompt.id,
                    acquisitionID: acquisitionID
                )
            }
            onPresentationRequired()
            publishRequirement()
        }
    }

    private func resumePrompt(with response: String) {
        guard let pendingPrompt else { return }
        self.pendingPrompt = nil
        pendingPrompt.deadlineTask?.cancel()
        pendingPrompt.continuation.resume(returning: response)
    }

    private func expirePrompt(id: String, acquisitionID: UUID) {
        guard let pendingPrompt,
              pendingPrompt.prompt.id == id,
              pendingPrompt.acquisitionID == acquisitionID,
              self.acquisitionID == acquisitionID
        else { return }
        self.pendingPrompt = nil
        hostKeyConfirmation = nil
        state = .failed(Self.promptTimedOut.localizedDescription)
        pendingPrompt.continuation.resume(throwing: Self.promptTimedOut)
        publishRequirement()
    }

    private func cancelAcquisition() {
        let canceledID = cancelLocalAcquisition()
        if let canceledID {
            let coordinator = coordinator
            let request = request
            Task {
                await coordinator.cancel(
                    request: request,
                    subscriberID: canceledID
                )
            }
        }
    }

    private func cancelLocalAcquisition(
        retainingRetryWaiters: Bool = false
    ) -> UUID? {
        let canceledID = acquisitionID
        acquisitionID = nil
        acquisitionTask?.cancel()
        acquisitionTask = nil
        terminalFailureTask?.cancel()
        terminalFailureTask = nil
        if let pendingPrompt {
            self.pendingPrompt = nil
            pendingPrompt.deadlineTask?.cancel()
            pendingPrompt.continuation.resume(throwing: CancellationError())
        }
        let waiters = requirementWaiters
        requirementWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: Self.cancelledRequirement)
        }
        publishConnection(
            .failure(CancellationError()),
            retainingRetryWaiters: retainingRetryWaiters
        )
        connectionFailure = CancellationError()
        return canceledID
    }

    private func publishRequirement() {
        guard let result = currentRequirement else { return }
        let waiters = requirementWaiters
        requirementWaiters.removeAll()
        waiters.values.forEach { $0.resume(returning: result) }
    }

    private func publishConnection(
        _ result: Result<KwtSSHConnection, Error>,
        retainingRetryWaiters: Bool = false
    ) {
        let waiters = handoffWaiters
        if retainingRetryWaiters, case .failure = result {
            handoffWaiters = waiters.filter {
                $0.value.waitsAcrossRetries
            }
        } else {
            handoffWaiters.removeAll()
        }
        waiters.values
            .filter {
                !retainingRetryWaiters || !$0.waitsAcrossRetries
            }
            .forEach { $0.continuation.resume(returning: result) }
    }

    private func waitForConnection(
        waitingAcrossRetries: Bool
    ) async throws -> KwtSSHConnection {
        if let connection {
            return connection
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedContinuation {
                (continuation: CheckedContinuation<
                    Result<KwtSSHConnection, Error>, Never
                >) in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(
                        CancellationError()
                    ))
                } else if let connection {
                    continuation.resume(returning: .success(connection))
                } else if connectionWasHandedOff {
                    continuation.resume(returning: .failure(
                        Self.connectionAlreadyHandedOff
                    ))
                } else if let connectionFailure, !waitingAcrossRetries {
                    continuation.resume(returning: .failure(
                        connectionFailure
                    ))
                } else {
                    handoffWaiters[waiterID] = HandoffWaiter(
                        waitsAcrossRetries: waitingAcrossRetries,
                        continuation: continuation
                    )
                }
            }.get()
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelConnectionWaiter(waiterID)
            }
        }
    }

    private func cancelConnectionWaiter(_ waiterID: UUID) {
        handoffWaiters.removeValue(forKey: waiterID)?
            .continuation.resume(returning: .failure(CancellationError()))
    }

    private func observeTerminalFailure(
        _ connection: KwtSSHConnection,
        acquisitionID: UUID
    ) {
        terminalFailureTask?.cancel()
        terminalFailureTask = Task { [weak self] in
            guard let failure = await connection.terminalFailure.value,
                  !Task.isCancelled,
                  let self,
                  self.connection === connection,
                  connection.generation == self.connection?.generation
            else { return }
            self.connection = nil
            connectionFailure = failure
            state = .failed(
                failure.localizedDescription
            )
            let retainsRetryWaiters = needsPresentation
            if retainsRetryWaiters {
                onPresentationRequired()
            }
            if self.acquisitionID == acquisitionID {
                self.acquisitionID = nil
            }
            publishRequirement()
            publishConnection(
                .failure(failure),
                retainingRetryWaiters: retainsRetryWaiters
            )
            Task { try? await connection.release() }
        }
    }

    private static func hostInfo(_ target: KwtSSHTarget) -> SSHHostInfo {
        SSHHostInfo(
            user: target.user,
            hostname: target.hostname,
            port: target.port
        )
    }

    private static var promptTimedOut: KwtSSHLeaseError {
        .operationFailed(
            code: "ssh_prompt_timed_out",
            message: "SSH prompt timed out.",
            retryable: false
        )
    }

    private static var connectionAlreadyHandedOff: KwtSSHLeaseError {
        .operationFailed(
            code: "ssh_connection_changed",
            message: "The SSH connection was already handed off.",
            retryable: true
        )
    }

    private static func promptDeadline(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    deinit {
        acquisitionTask?.cancel()
        terminalFailureTask?.cancel()
        if let acquisitionID {
            let coordinator = coordinator
            let request = request
            Task {
                await coordinator.cancel(
                    request: request,
                    subscriberID: acquisitionID
                )
            }
        }
        if let pendingPrompt {
            pendingPrompt.deadlineTask?.cancel()
            pendingPrompt.continuation.resume(throwing: CancellationError())
        }
        if let connection {
            Task { try? await connection.release() }
        }
        let handoffs = handoffWaiters
        handoffWaiters.removeAll()
        for waiter in handoffs.values {
            waiter.continuation.resume(returning: .failure(
                CancellationError()
            ))
        }
    }
}
