import Combine
import Foundation

public enum TerminalFindDirection: Equatable, Sendable {
    case next
    case previous
}

public struct TerminalFindOperationToken: Hashable, Sendable {
    private let value = UUID()

    public init() {}
}

public enum TerminalFindResult: Equatable, Sendable {
    case idle
    case match(total: UInt?, selected: UInt?)
    case noMatch
}

public enum TerminalFindBackendResponse: Equatable, Sendable {
    case result(TerminalFindResult)
    case awaitingCallback
}

public struct TerminalFindFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct TerminalFindSession: Sendable {
    public let search: @Sendable (String, TerminalFindOperationToken) async
        -> Result<TerminalFindBackendResponse, TerminalFindFailure>
    public let navigate: @Sendable (
        TerminalFindDirection, TerminalFindOperationToken
    ) async
        -> Result<TerminalFindBackendResponse, TerminalFindFailure>
    public let close: @Sendable () async -> TerminalFindFailure?

    public init(
        search: @escaping @Sendable (
            String, TerminalFindOperationToken
        ) async
            -> Result<TerminalFindBackendResponse, TerminalFindFailure>,
        navigate: @escaping @Sendable (
            TerminalFindDirection, TerminalFindOperationToken
        ) async
            -> Result<TerminalFindBackendResponse, TerminalFindFailure>,
        close: @escaping @Sendable () async -> TerminalFindFailure?
    ) {
        self.search = search
        self.navigate = navigate
        self.close = close
    }
}

@MainActor
public final class TerminalFindController: ObservableObject {
    @Published public private(set) var isOpen = false
    @Published public private(set) var query = ""
    @Published public private(set) var result: TerminalFindResult = .idle
    @Published public private(set) var isWorking = false
    @Published public private(set) var failureMessage: String?
    @Published public private(set) var fieldSelectionRevision: UInt64 = 0

    public let isAvailable: Bool

    private let debounce: Duration
    private let sessionProvider: @MainActor @Sendable () -> TerminalFindSession?
    private let failureHandler: @MainActor @Sendable (String) -> Void
    private var findSessionID = UUID()
    private var queryGeneration: UInt64 = 0
    private var callbackRevision: UInt64 = 0
    private var backendTotal = -1
    private var backendSelected = -1
    private var activeSession: TerminalFindSession?
    private var pendingSearch: Operation?
    private var pendingNavigations: [Operation] = []
    private var pendingEnds: [Operation] = []
    private var debounceTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var activeBackendTask: BackendTask?
    private var callbackWaiter: CallbackWaiter?
    private var activeCallbackOperation: CallbackOperation?

    public init(
        isAvailable: Bool,
        debounce: Duration = .milliseconds(150),
        failureHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        sessionProvider: @escaping @MainActor @Sendable ()
            -> TerminalFindSession?
    ) {
        self.isAvailable = isAvailable
        self.debounce = debounce
        self.failureHandler = failureHandler
        self.sessionProvider = sessionProvider
    }

    public static var unavailable: TerminalFindController {
        TerminalFindController(isAvailable: false, sessionProvider: { nil })
    }

    public var canNavigate: Bool {
        guard isAvailable, isOpen, !query.isEmpty else { return false }
        if case .match = result {
            return true
        }
        return false
    }

    public func open() {
        guard isAvailable else { return }
        if isOpen {
            fieldSelectionRevision &+= 1
            return
        }

        findSessionID = UUID()
        activeSession = nil
        activeCallbackOperation = nil
        isOpen = true
        failureMessage = nil
        resetBackendResult()
        result = .idle
        fieldSelectionRevision &+= 1
        if !query.isEmpty {
            scheduleSearch(query)
        }
    }

    public func updateQuery(_ value: String) {
        guard isAvailable, isOpen else { return }
        query = value
        queryGeneration &+= 1
        result = .idle
        failureMessage = nil
        resetBackendResult()
        pendingSearch = nil
        pendingNavigations.removeAll()
        debounceTask?.cancel()
        cancelActiveBackendTask()
        activeCallbackOperation = nil
        resumeCallbackWaiter()
        isWorking = false

        if value.isEmpty {
            endActiveBackendSession()
        } else {
            scheduleSearch(value)
        }
    }

    public func findNext() {
        enqueueNavigation(.next)
    }

    public func findPrevious() {
        enqueueNavigation(.previous)
    }

    public func close() {
        close(notifyBackend: true, clearFailure: true)
    }

    public func backendDidOpen(
        query value: String,
        operation: TerminalFindOperationToken
    ) {
        guard isAvailable else { return }
        let opensBar = !isOpen
        let replacesActiveOperation = activeCallbackOperation.map {
            $0.token != operation
        } ?? false
        if opensBar {
            findSessionID = UUID()
            activeSession = nil
            query = value
            queryGeneration &+= 1
        } else if replacesActiveOperation {
            query = value
            queryGeneration &+= 1
            pendingSearch = nil
            pendingNavigations.removeAll()
            debounceTask?.cancel()
            debounceTask = nil
            cancelActiveBackendTask()
            activeCallbackOperation = nil
            resumeCallbackWaiter()
            isWorking = false
        } else if query != value {
            query = value
            queryGeneration &+= 1
            result = .idle
            failureMessage = nil
        }
        let callbackOperation = CallbackOperation(
            token: operation,
            sessionID: findSessionID,
            generation: queryGeneration,
            expectedCallback: .total
        )
        activeCallbackOperation = callbackOperation
        callbackRevision &+= 1
        resumeCallbackWaiter(matching: operation)
        activeSession = activeSession ?? sessionProvider()
        isOpen = true
        resetBackendResult()
        result = .idle
        failureMessage = nil
        isWorking = false
        if opensBar {
            fieldSelectionRevision &+= 1
        }
    }

    public func backendDidEnd(operation: TerminalFindOperationToken) {
        guard activeCallbackOperation?.token == operation else { return }
        callbackRevision &+= 1
        resumeCallbackWaiter(matching: operation)
        close(notifyBackend: false, clearFailure: true)
    }

    public func publishBackendTotal(
        _ total: Int,
        operation: TerminalFindOperationToken
    ) {
        publishBackendCallback(
            .total,
            value: total,
            operation: operation
        )
    }

    public func publishBackendSelected(
        _ selected: Int,
        operation: TerminalFindOperationToken
    ) {
        publishBackendCallback(
            .selected,
            value: selected,
            operation: operation
        )
    }

    private func publishBackendCallback(
        _ callback: CallbackKind,
        value: Int,
        operation: TerminalFindOperationToken
    ) {
        guard isOpen,
              let callbackOperation = activeCallbackOperation,
              callbackOperation.token == operation,
              isCurrent(
                  sessionID: callbackOperation.sessionID,
                  generation: callbackOperation.generation
              )
        else { return }

        switch callback {
        case .total:
            backendTotal = value
        case .selected:
            backendSelected = value
        }
        result = Self.result(total: backendTotal, selected: backendSelected)

        if callbackOperation.expectedCallback == callback {
            callbackRevision &+= 1
            resumeCallbackWaiter(matching: operation)
            isWorking = false
        }
    }

    private func scheduleSearch(_ value: String) {
        let sessionID = findSessionID
        let generation = queryGeneration
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard isOpen,
                  query == value,
                  findSessionID == sessionID,
                  queryGeneration == generation
            else { return }
            pendingSearch = .search(
                value,
                sessionID: sessionID,
                generation: generation
            )
            startWorkerIfNeeded()
        }
    }

    private func enqueueNavigation(_ direction: TerminalFindDirection) {
        guard canNavigate else { return }
        pendingNavigations.append(.navigate(
            direction,
            sessionID: findSessionID,
            generation: queryGeneration
        ))
        startWorkerIfNeeded()
    }

    private func endActiveBackendSession() {
        let session = activeSession
        activeSession = nil
        guard let session else {
            isWorking = false
            return
        }
        pendingEnds.append(.end(session))
        startWorkerIfNeeded()
    }

    private func close(notifyBackend: Bool, clearFailure: Bool) {
        guard isOpen else { return }
        let session = activeSession
        debounceTask?.cancel()
        debounceTask = nil
        pendingSearch = nil
        pendingNavigations.removeAll()
        queryGeneration &+= 1
        cancelActiveBackendTask()
        resumeCallbackWaiter()
        isOpen = false
        result = .idle
        resetBackendResult()
        isWorking = false
        activeCallbackOperation = nil
        if clearFailure {
            failureMessage = nil
        }
        activeSession = nil
        if notifyBackend, let session {
            pendingEnds.append(.end(session))
            startWorkerIfNeeded()
        }
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while let operation = nextOperation() {
            switch operation {
            case let .search(value, sessionID, generation):
                guard isCurrent(sessionID: sessionID, generation: generation),
                      let session = activeSession ?? sessionProvider()
                else { continue }
                activeSession = session
                isWorking = true
                let callbackOperation = CallbackOperation(
                    token: TerminalFindOperationToken(),
                    sessionID: sessionID,
                    generation: generation,
                    expectedCallback: .total
                )
                resetBackendResult()
                activeCallbackOperation = callbackOperation
                let revision = callbackRevision
                let response = await performBackendOperation {
                    await session.search(
                        value,
                        callbackOperation.token
                    )
                }
                await handle(
                    response,
                    callbackOperation: callbackOperation,
                    callbackRevision: revision
                )

            case let .navigate(direction, sessionID, generation):
                guard isCurrent(sessionID: sessionID, generation: generation),
                      let session = activeSession
                else { continue }
                isWorking = true
                let callbackOperation = CallbackOperation(
                    token: TerminalFindOperationToken(),
                    sessionID: sessionID,
                    generation: generation,
                    expectedCallback: .selected
                )
                activeCallbackOperation = callbackOperation
                let revision = callbackRevision
                let response = await performBackendOperation {
                    await session.navigate(
                        direction,
                        callbackOperation.token
                    )
                }
                await handle(
                    response,
                    callbackOperation: callbackOperation,
                    callbackRevision: revision
                )

            case let .end(session):
                _ = await session.close()
            }
        }
        workerTask = nil
    }

    private func performBackendOperation(
        _ operation: @escaping @Sendable () async
            -> Result<TerminalFindBackendResponse, TerminalFindFailure>
    ) async -> Result<TerminalFindBackendResponse, TerminalFindFailure> {
        let id = UUID()
        let task = Task { await operation() }
        activeBackendTask = BackendTask(id: id, task: task)
        let response = await task.value
        if activeBackendTask?.id == id {
            activeBackendTask = nil
        }
        return response
    }

    private func cancelActiveBackendTask() {
        activeBackendTask?.task.cancel()
    }

    private func resetBackendResult() {
        backendTotal = -1
        backendSelected = -1
    }

    private func nextOperation() -> Operation? {
        if !pendingEnds.isEmpty {
            return pendingEnds.removeFirst()
        }
        if let search = pendingSearch {
            pendingSearch = nil
            return search
        }
        if !pendingNavigations.isEmpty {
            return pendingNavigations.removeFirst()
        }
        return nil
    }

    private func handle(
        _ response: Result<TerminalFindBackendResponse, TerminalFindFailure>,
        callbackOperation: CallbackOperation,
        callbackRevision initialRevision: UInt64
    ) async {
        guard isCurrent(
            sessionID: callbackOperation.sessionID,
            generation: callbackOperation.generation
        ) else {
            return
        }
        switch response {
        case let .success(.result(value)):
            result = value
            isWorking = false
            if activeCallbackOperation == callbackOperation {
                activeCallbackOperation = nil
            }
        case .success(.awaitingCallback):
            guard callbackRevision == initialRevision else {
                isWorking = false
                return
            }
            await waitForBackendCallback(callbackOperation)
        case let .failure(failure):
            failureMessage = failure.message
            failureHandler(failure.message)
            close(notifyBackend: true, clearFailure: false)
        }
    }

    private func waitForBackendCallback(
        _ operation: CallbackOperation
    ) async {
        await withCheckedContinuation { continuation in
            callbackWaiter = CallbackWaiter(
                operation: operation,
                continuation: continuation
            )
        }
    }

    private func resumeCallbackWaiter(
        matching token: TerminalFindOperationToken
    ) {
        guard callbackWaiter?.operation.token == token else { return }
        resumeCallbackWaiter()
    }

    private func resumeCallbackWaiter() {
        let continuation = callbackWaiter?.continuation
        callbackWaiter = nil
        continuation?.resume()
    }

    private func isCurrent(sessionID: UUID, generation: UInt64) -> Bool {
        isOpen && findSessionID == sessionID && queryGeneration == generation
    }

    private static func result(total: Int, selected: Int?) -> TerminalFindResult {
        guard total >= 0 else { return .idle }
        guard total > 0 else { return .noMatch }
        let selectedIndex = selected.flatMap { value -> UInt? in
            guard value >= 0 else { return nil }
            return UInt(value) + 1
        }
        return .match(total: UInt(total), selected: selectedIndex)
    }

    private enum Operation {
        case search(String, sessionID: UUID, generation: UInt64)
        case navigate(
            TerminalFindDirection,
            sessionID: UUID,
            generation: UInt64
        )
        case end(TerminalFindSession)
    }

    private struct CallbackWaiter {
        let operation: CallbackOperation
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct BackendTask {
        let id: UUID
        let task: Task<
            Result<TerminalFindBackendResponse, TerminalFindFailure>,
            Never
        >
    }

    private struct CallbackOperation: Equatable {
        let token: TerminalFindOperationToken
        let sessionID: UUID
        let generation: UInt64
        let expectedCallback: CallbackKind
    }

    private enum CallbackKind: Equatable {
        case total
        case selected
    }
}
