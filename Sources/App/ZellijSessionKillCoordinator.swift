@preconcurrency import Combine
import Foundation
import GhosthubTransport

@MainActor
final class ZellijSessionKillCoordinator {
    struct Key: Hashable, Sendable {
        let hostID: UUID
        let sessionName: String
    }

    enum Phase: Equatable, Sendable {
        case began
        case succeeded
        case failed
    }

    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed
    }

    struct Operation: Identifiable, Equatable, Sendable {
        let id: UUID
        let key: Key
        let host: CommandHost
        let connectionCacheKey: SSHConnectionArgumentsCacheKey
    }

    struct Event: Equatable, Sendable {
        let operation: Operation
        let phase: Phase
    }

    static let shared = ZellijSessionKillCoordinator()

    private var activeOperations: [Key: Operation] = [:]
    private var revisions: [Key: UInt64] = [:]
    private let eventSubject = PassthroughSubject<Event, Never>()

    var events: AnyPublisher<Event, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    func begin(
        key: Key,
        host: CommandHost,
        connectionCacheKey: SSHConnectionArgumentsCacheKey
    ) -> Operation? {
        guard activeOperations[key] == nil else { return nil }
        let operation = Operation(
            id: UUID(),
            key: key,
            host: host,
            connectionCacheKey: connectionCacheKey
        )
        activeOperations[key] = operation
        revisions[key, default: 0] &+= 1
        eventSubject.send(Event(operation: operation, phase: .began))
        return operation
    }

    func finish(_ operation: Operation, outcome: Outcome) {
        guard activeOperations[operation.key] == operation else { return }
        activeOperations.removeValue(forKey: operation.key)
        eventSubject.send(Event(
            operation: operation,
            phase: outcome == .succeeded ? .succeeded : .failed
        ))
    }

    func isPending(_ key: Key) -> Bool {
        activeOperations[key] != nil
    }

    func revision(for key: Key) -> UInt64 {
        revisions[key, default: 0]
    }
}
