@preconcurrency import Combine
import Foundation

@MainActor
final class HerdrSessionLifecycleCoordinator {
    struct Key: Hashable, Sendable {
        let hostID: UUID
        let sessionName: String
    }

    enum OperationKind: Equatable, Sendable {
        case create
        case stop
        case restart
        case delete
    }

    enum Phase: Equatable, Sendable {
        case began
        case willStop
        case succeeded
        case failed
    }

    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed
    }

    struct Operation: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: OperationKind
        let key: Key
    }

    struct Event: Equatable, Sendable {
        let operation: Operation
        let phase: Phase
    }

    static let shared = HerdrSessionLifecycleCoordinator()

    private var activeOperations: [Key: Operation] = [:]
    private var revisions: [UUID: UInt64] = [:]
    private let eventSubject = PassthroughSubject<Event, Never>()

    var events: AnyPublisher<Event, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    func begin(_ kind: OperationKind, key: Key) -> Operation? {
        guard activeOperations[key] == nil else { return nil }
        let operation = Operation(id: UUID(), kind: kind, key: key)
        activeOperations[key] = operation
        eventSubject.send(Event(operation: operation, phase: .began))
        return operation
    }

    func willStop(_ operation: Operation) {
        guard activeOperations[operation.key] == operation else { return }
        eventSubject.send(Event(operation: operation, phase: .willStop))
    }

    func finish(_ operation: Operation, outcome: Outcome) {
        guard activeOperations[operation.key] == operation else { return }
        activeOperations.removeValue(forKey: operation.key)
        revisions[operation.key.hostID, default: 0] &+= 1
        eventSubject.send(Event(
            operation: operation,
            phase: outcome == .succeeded ? .succeeded : .failed
        ))
    }

    func isPending(_ key: Key) -> Bool {
        activeOperations[key] != nil
    }

    var pendingKeys: Set<Key> {
        Set(activeOperations.keys)
    }

    func revision(for hostID: UUID) -> UInt64 {
        revisions[hostID, default: 0]
    }
}
