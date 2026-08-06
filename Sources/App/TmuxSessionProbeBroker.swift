import Foundation
import GhosthubTmux

struct TmuxSessionProbeTarget: Hashable, Sendable {
    var host: SSHHostInfo
    var name: String
    var socketName: String?
}

enum TmuxSessionProbeOutcome: Equatable, Sendable {
    case present
    case absent
    case failure(TmuxBinaryError)
}

@MainActor
final class TmuxSessionProbeBroker {
    typealias Discovery = @Sendable (TmuxHost) async
        -> Result<[DiscoveredTmuxSession], TmuxBinaryError>
    typealias ExactProbe = @Sendable (TmuxSessionProbeTarget) async
        -> Result<Bool, TmuxBinaryError>
    private typealias DiscoveryResult =
        Result<[DiscoveredTmuxSession], TmuxBinaryError>
    private typealias DiscoveryContinuation =
        CheckedContinuation<DiscoveryResult, Never>
    private typealias ExactProbeResult = Result<Bool, TmuxBinaryError>
    private typealias ExactProbeContinuation =
        CheckedContinuation<ExactProbeResult, Never>

    private struct DiscoveryEntry {
        var id: UUID
        var task: Task<Void, Never>
        var consumers: [UUID: DiscoveryContinuation]
        var consumersWaitingForCancellation: [UUID: DiscoveryContinuation]
        var isCancelling = false
    }

    private struct ExactProbeEntry {
        var id: UUID
        var task: Task<Void, Never>
        var consumers: [UUID: ExactProbeContinuation]
        var consumersWaitingForCancellation: [UUID: ExactProbeContinuation]
        var isCancelling = false
    }

    private let discover: Discovery
    private let exactProbe: ExactProbe
    private var discoveryEntries = [TmuxHost: DiscoveryEntry]()
    private var exactProbeEntries = [TmuxSessionProbeTarget: ExactProbeEntry]()

    init(
        discover: @escaping Discovery,
        exactProbe: @escaping ExactProbe
    ) {
        self.discover = discover
        self.exactProbe = exactProbe
    }

    func sessions(
        on host: TmuxHost
    ) async -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        let consumerID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(
                        .probeCancelled(shell: host.displayName)
                    ))
                    return
                }
                registerDiscoveryConsumer(
                    continuation,
                    id: consumerID,
                    host: host
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelDiscoveryConsumer(id: consumerID, host: host)
            }
        }
    }

    func invalidateSessions(on host: TmuxHost) {
        guard var entry = discoveryEntries[host] else {
            return
        }
        let failure = DiscoveryResult.failure(
            .probeCancelled(shell: host.displayName)
        )
        for value in entry.consumers.values {
            value.resume(returning: failure)
        }
        for value in entry.consumersWaitingForCancellation.values {
            value.resume(returning: failure)
        }
        entry.consumers.removeAll()
        entry.consumersWaitingForCancellation.removeAll()
        entry.isCancelling = true
        entry.task.cancel()
        discoveryEntries[host] = entry
    }

    func session(
        _ target: TmuxSessionProbeTarget
    ) async -> TmuxSessionProbeOutcome {
        guard target.socketName != nil else {
            switch await sessions(on: .ssh(target.host)) {
            case let .success(sessions):
                return sessions.contains(where: { $0.name == target.name })
                    ? .present
                    : .absent
            case let .failure(error):
                return .failure(error)
            }
        }

        let consumerID = UUID()
        let result: ExactProbeResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(
                        .probeCancelled(shell: target.host.displayName)
                    ))
                    return
                }
                registerExactProbeConsumer(
                    continuation,
                    id: consumerID,
                    target: target
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelExactProbeConsumer(
                    id: consumerID,
                    target: target
                )
            }
        }
        return Self.outcome(for: result)
    }

    private func registerDiscoveryConsumer(
        _ continuation: DiscoveryContinuation,
        id consumerID: UUID,
        host: TmuxHost
    ) {
        guard var entry = discoveryEntries[host] else {
            startDiscovery(
                on: host,
                consumers: [consumerID: continuation]
            )
            return
        }
        if entry.isCancelling {
            entry.consumersWaitingForCancellation[consumerID] = continuation
        } else {
            entry.consumers[consumerID] = continuation
        }
        discoveryEntries[host] = entry
    }

    private func startDiscovery(
        on host: TmuxHost,
        consumers: [UUID: DiscoveryContinuation]
    ) {
        let id = UUID()
        let discover = discover
        let task = Task {
            let result = await discover(host)
            self.completeDiscovery(result, id: id, host: host)
        }
        discoveryEntries[host] = DiscoveryEntry(
            id: id,
            task: task,
            consumers: consumers,
            consumersWaitingForCancellation: [:]
        )
    }

    private func completeDiscovery(
        _ result: DiscoveryResult,
        id: UUID,
        host: TmuxHost
    ) {
        guard let entry = discoveryEntries[host], entry.id == id else {
            return
        }
        discoveryEntries.removeValue(forKey: host)
        if entry.isCancelling {
            if !entry.consumersWaitingForCancellation.isEmpty {
                startDiscovery(
                    on: host,
                    consumers: entry.consumersWaitingForCancellation
                )
            }
            return
        }
        for value in entry.consumers.values {
            value.resume(returning: result)
        }
    }

    private func cancelDiscoveryConsumer(id: UUID, host: TmuxHost) {
        guard var entry = discoveryEntries[host] else { return }
        let failure = DiscoveryResult.failure(
            .probeCancelled(shell: host.displayName)
        )
        if let consumer = entry.consumers.removeValue(forKey: id) {
            consumer.resume(returning: failure)
            if entry.consumers.isEmpty {
                entry.isCancelling = true
                entry.task.cancel()
            }
        } else if let consumer = entry.consumersWaitingForCancellation
            .removeValue(forKey: id) {
            consumer.resume(returning: failure)
        }
        discoveryEntries[host] = entry
    }

    private func registerExactProbeConsumer(
        _ continuation: ExactProbeContinuation,
        id consumerID: UUID,
        target: TmuxSessionProbeTarget
    ) {
        guard var entry = exactProbeEntries[target] else {
            startExactProbe(
                target,
                consumers: [consumerID: continuation]
            )
            return
        }
        if entry.isCancelling {
            entry.consumersWaitingForCancellation[consumerID] = continuation
        } else {
            entry.consumers[consumerID] = continuation
        }
        exactProbeEntries[target] = entry
    }

    private func startExactProbe(
        _ target: TmuxSessionProbeTarget,
        consumers: [UUID: ExactProbeContinuation]
    ) {
        let id = UUID()
        let exactProbe = exactProbe
        let task = Task {
            let result = await exactProbe(target)
            self.completeExactProbe(result, id: id, target: target)
        }
        exactProbeEntries[target] = ExactProbeEntry(
            id: id,
            task: task,
            consumers: consumers,
            consumersWaitingForCancellation: [:]
        )
    }

    private func completeExactProbe(
        _ result: ExactProbeResult,
        id: UUID,
        target: TmuxSessionProbeTarget
    ) {
        guard let entry = exactProbeEntries[target], entry.id == id else {
            return
        }
        exactProbeEntries.removeValue(forKey: target)
        if entry.isCancelling {
            if !entry.consumersWaitingForCancellation.isEmpty {
                startExactProbe(
                    target,
                    consumers: entry.consumersWaitingForCancellation
                )
            }
            return
        }
        for value in entry.consumers.values {
            value.resume(returning: result)
        }
    }

    private func cancelExactProbeConsumer(
        id: UUID,
        target: TmuxSessionProbeTarget
    ) {
        guard var entry = exactProbeEntries[target] else { return }
        let failure = ExactProbeResult.failure(
            .probeCancelled(shell: target.host.displayName)
        )
        if let consumer = entry.consumers.removeValue(forKey: id) {
            consumer.resume(returning: failure)
            if entry.consumers.isEmpty {
                entry.isCancelling = true
                entry.task.cancel()
            }
        } else if let consumer = entry.consumersWaitingForCancellation
            .removeValue(forKey: id) {
            consumer.resume(returning: failure)
        }
        exactProbeEntries[target] = entry
    }

    private static func outcome(
        for result: Result<Bool, TmuxBinaryError>
    ) -> TmuxSessionProbeOutcome {
        switch result {
        case .success(true): .present
        case .success(false): .absent
        case let .failure(error): .failure(error)
        }
    }
}
