import Foundation
import GhosthubHerdr
import GhosthubTransport

enum HerdrSessionProbeOutcome: Equatable, Sendable {
    case present
    case absent
    case unavailable
    case failure(HerdrCommandError)

    static func exact(
        name: String,
        discovery: HerdrDiscoveryResult
    ) -> Self {
        switch discovery {
        case let .available(sessions):
            sessions.contains(where: {
                $0.name == name && $0.state == .running
            }) ? .present : .absent
        case .unavailable:
            .unavailable
        case let .failure(error):
            .failure(error)
        }
    }
}

@MainActor
final class HerdrSessionProbeBroker {
    typealias Discovery = @Sendable (CommandHost) async
        -> HerdrDiscoveryResult
    private typealias Continuation =
        CheckedContinuation<HerdrDiscoveryResult, Never>

    private struct Entry {
        var id: UUID
        var task: Task<Void, Never>
        var consumers: [UUID: Continuation]
        var consumersWaitingForCancellation: [UUID: Continuation]
        var isCancelling = false
    }

    private let discover: Discovery
    private var entries = [CommandHost: Entry]()

    init(discover: @escaping Discovery) {
        self.discover = discover
    }

    func sessions(on host: CommandHost) async -> HerdrDiscoveryResult {
        let consumerID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: cancellation(on: host))
                    return
                }
                register(continuation, id: consumerID, host: host)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelConsumer(id: consumerID, host: host)
            }
        }
    }

    func session(
        named name: String,
        on host: CommandHost
    ) async -> HerdrSessionProbeOutcome {
        await .exact(name: name, discovery: sessions(on: host))
    }

    func invalidateSessions(on host: CommandHost) {
        guard var entry = entries[host] else { return }
        let result = cancellation(on: host)
        for continuation in entry.consumers.values {
            continuation.resume(returning: result)
        }
        for continuation in entry.consumersWaitingForCancellation.values {
            continuation.resume(returning: result)
        }
        entry.consumers.removeAll()
        entry.consumersWaitingForCancellation.removeAll()
        entry.isCancelling = true
        entry.task.cancel()
        entries[host] = entry
    }

    private func register(
        _ continuation: Continuation,
        id consumerID: UUID,
        host: CommandHost
    ) {
        guard var entry = entries[host] else {
            start(on: host, consumers: [consumerID: continuation])
            return
        }
        if entry.isCancelling {
            entry.consumersWaitingForCancellation[consumerID] = continuation
        } else {
            entry.consumers[consumerID] = continuation
        }
        entries[host] = entry
    }

    private func start(
        on host: CommandHost,
        consumers: [UUID: Continuation]
    ) {
        let id = UUID()
        let discover = discover
        let task = Task {
            let result = await discover(host)
            complete(result, id: id, host: host)
        }
        entries[host] = Entry(
            id: id,
            task: task,
            consumers: consumers,
            consumersWaitingForCancellation: [:]
        )
    }

    private func complete(
        _ result: HerdrDiscoveryResult,
        id: UUID,
        host: CommandHost
    ) {
        guard let entry = entries[host], entry.id == id else { return }
        entries.removeValue(forKey: host)
        if entry.isCancelling {
            if !entry.consumersWaitingForCancellation.isEmpty {
                start(
                    on: host,
                    consumers: entry.consumersWaitingForCancellation
                )
            }
            return
        }
        for continuation in entry.consumers.values {
            continuation.resume(returning: result)
        }
    }

    private func cancelConsumer(id: UUID, host: CommandHost) {
        guard var entry = entries[host] else { return }
        let result = cancellation(on: host)
        if let consumer = entry.consumers.removeValue(forKey: id) {
            consumer.resume(returning: result)
            if entry.consumers.isEmpty {
                entry.isCancelling = true
                entry.task.cancel()
            }
        } else if let consumer = entry.consumersWaitingForCancellation
            .removeValue(forKey: id) {
            consumer.resume(returning: result)
        }
        entries[host] = entry
    }

    private func cancellation(
        on host: CommandHost
    ) -> HerdrDiscoveryResult {
        .failure(.cancelled(host: host.displayName))
    }
}
