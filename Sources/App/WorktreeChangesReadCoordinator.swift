import Foundation
import GhosthubUI
import GhosthubWorkspace

actor WorktreeChangesReadCoordinator {
    static let shared = WorktreeChangesReadCoordinator(
        globalLimit: 4,
        perHostLimit: 2
    )

    typealias Operation = @Sendable () async throws -> WorktreeFileChanges

    private struct WaiterKey: Hashable, Sendable {
        let identity: WorktreeChangesIdentity
        let id: UUID
    }

    private struct ExecutionTarget: Hashable, Sendable {
        let hostID: UUID
        let worktreeID: UUID
    }

    private struct Entry {
        let hostID: UUID
        let operation: Operation
        var waiters: [UUID: CheckedContinuation<WorktreeFileChanges, Error>]
        var replacementWaiters:
            [UUID: CheckedContinuation<WorktreeFileChanges, Error>]
        var replacementOperation: Operation?
        var task: Task<Void, Never>?
        var isCancelling: Bool
    }

    private let globalLimit: Int
    private let perHostLimit: Int
    private var entries: [WorktreeChangesIdentity: Entry] = [:]
    private var queue: [WorktreeChangesIdentity] = []
    private var activeCount = 0
    private var activeByHost: [UUID: Int] = [:]
    private var activeExecutionTargets: Set<ExecutionTarget> = []

    init(globalLimit: Int, perHostLimit: Int) {
        precondition(globalLimit > 0)
        precondition(perHostLimit > 0)
        self.globalLimit = globalLimit
        self.perHostLimit = perHostLimit
    }

    func load(
        identity: WorktreeChangesIdentity,
        operation: @escaping Operation
    ) async throws -> WorktreeFileChanges {
        let key = WaiterKey(identity: identity, id: UUID())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(
                    key: key,
                    operation: operation,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(key: key) }
        }
    }

    private func enqueue(
        key: WaiterKey,
        operation: @escaping Operation,
        continuation: CheckedContinuation<WorktreeFileChanges, Error>
    ) {
        if var entry = entries[key.identity] {
            if entry.isCancelling {
                entry.replacementWaiters[key.id] = continuation
                entry.replacementOperation = operation
            } else {
                entry.waiters[key.id] = continuation
            }
            entries[key.identity] = entry
            return
        }
        entries[key.identity] = Entry(
            hostID: key.identity.hostID,
            operation: operation,
            waiters: [key.id: continuation],
            replacementWaiters: [:],
            replacementOperation: nil,
            task: nil,
            isCancelling: false
        )
        queue.append(key.identity)
        schedule()
    }

    private func cancel(key: WaiterKey) {
        guard var entry = entries[key.identity] else {
            return
        }
        if let continuation = entry.replacementWaiters.removeValue(
            forKey: key.id
        ) {
            continuation.resume(throwing: CancellationError())
            entries[key.identity] = entry
            return
        }
        guard let continuation = entry.waiters.removeValue(forKey: key.id)
        else { return }
        continuation.resume(throwing: CancellationError())
        if entry.waiters.isEmpty {
            if let task = entry.task {
                entry.isCancelling = true
                entries[key.identity] = entry
                task.cancel()
            } else {
                entries.removeValue(forKey: key.identity)
                queue.removeAll { $0 == key.identity }
            }
        } else {
            entries[key.identity] = entry
        }
    }

    private func schedule() {
        while activeCount < globalLimit,
              let queueIndex = queue.firstIndex(where: { identity in
                  guard let entry = entries[identity] else { return false }
                  return activeByHost[entry.hostID, default: 0] < perHostLimit
                      && !activeExecutionTargets.contains(
                          executionTarget(for: identity)
                      )
              }) {
            let identity = queue.remove(at: queueIndex)
            guard var entry = entries[identity], entry.task == nil else {
                continue
            }
            activeCount += 1
            activeByHost[entry.hostID, default: 0] += 1
            activeExecutionTargets.insert(executionTarget(for: identity))
            let operation = entry.operation
            entry.task = Task {
                let result: Result<WorktreeFileChanges, Error>
                do {
                    result = await .success(try operation())
                } catch {
                    result = .failure(error)
                }
                self.finish(identity: identity, result: result)
            }
            entries[identity] = entry
        }
    }

    private func finish(
        identity: WorktreeChangesIdentity,
        result: Result<WorktreeFileChanges, Error>
    ) {
        guard let entry = entries.removeValue(forKey: identity) else {
            return
        }
        activeCount -= 1
        activeExecutionTargets.remove(executionTarget(for: identity))
        let remainingForHost = activeByHost[entry.hostID, default: 1] - 1
        if remainingForHost == 0 {
            activeByHost.removeValue(forKey: entry.hostID)
        } else {
            activeByHost[entry.hostID] = remainingForHost
        }
        if entry.isCancelling,
           !entry.replacementWaiters.isEmpty,
           let replacementOperation = entry.replacementOperation {
            entries[identity] = Entry(
                hostID: entry.hostID,
                operation: replacementOperation,
                waiters: entry.replacementWaiters,
                replacementWaiters: [:],
                replacementOperation: nil,
                task: nil,
                isCancelling: false
            )
            queue.append(identity)
        } else {
            for continuation in entry.waiters.values {
                continuation.resume(with: result)
            }
        }
        schedule()
    }

    private func executionTarget(
        for identity: WorktreeChangesIdentity
    ) -> ExecutionTarget {
        ExecutionTarget(
            hostID: identity.hostID,
            worktreeID: identity.worktreeID
        )
    }
}
