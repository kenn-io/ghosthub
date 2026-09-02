import Combine
import Foundation

public enum TerminalFindDirection: Equatable, Sendable {
    case next
    case previous
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
    public let search: @Sendable (String) async
        -> Result<TerminalFindBackendResponse, TerminalFindFailure>
    public let navigate: @Sendable (TerminalFindDirection) async
        -> Result<TerminalFindBackendResponse, TerminalFindFailure>
    public let close: @Sendable () async -> TerminalFindFailure?

    public init(
        search: @escaping @Sendable (String) async
            -> Result<TerminalFindBackendResponse, TerminalFindFailure>,
        navigate: @escaping @Sendable (TerminalFindDirection) async
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
    private var findSessionID = UUID()
    private var queryGeneration: UInt64 = 0
    private var callbackRevision: UInt64 = 0
    private var activeSession: TerminalFindSession?
    private var pendingSearch: Operation?
    private var pendingNavigations: [Operation] = []
    private var pendingEnds: [Operation] = []
    private var debounceTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var callbackWaiter: CallbackWaiter?

    public init(
        isAvailable: Bool,
        debounce: Duration = .milliseconds(150),
        sessionProvider: @escaping @MainActor @Sendable ()
            -> TerminalFindSession?
    ) {
        self.isAvailable = isAvailable
        self.debounce = debounce
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
        isOpen = true
        failureMessage = nil
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
        pendingSearch = nil
        pendingNavigations.removeAll()
        debounceTask?.cancel()

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

    public func backendDidOpen(query value: String) {
        guard isAvailable else { return }
        callbackRevision &+= 1
        resumeCallbackWaiter()
        if !isOpen {
            findSessionID = UUID()
            activeSession = nil
        }
        activeSession = activeSession ?? sessionProvider()
        isOpen = true
        query = value
        queryGeneration &+= 1
        result = .idle
        failureMessage = nil
        isWorking = false
        fieldSelectionRevision &+= 1
    }

    public func backendDidEnd() {
        callbackRevision &+= 1
        resumeCallbackWaiter()
        close(notifyBackend: false, clearFailure: true)
    }

    public func publishBackendResult(total: Int, selected: Int?) {
        guard isOpen else { return }
        callbackRevision &+= 1
        let shouldPublish = callbackWaiter.map {
            $0.sessionID == findSessionID
                && $0.generation == queryGeneration
        } ?? true
        resumeCallbackWaiter()
        guard shouldPublish else { return }

        result = Self.result(total: total, selected: selected)
        isWorking = false
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
        resumeCallbackWaiter()
        isOpen = false
        result = .idle
        isWorking = false
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
                let revision = callbackRevision
                let response = await session.search(value)
                await handle(
                    response,
                    sessionID: sessionID,
                    generation: generation,
                    callbackRevision: revision
                )

            case let .navigate(direction, sessionID, generation):
                guard isCurrent(sessionID: sessionID, generation: generation),
                      let session = activeSession
                else { continue }
                isWorking = true
                let revision = callbackRevision
                let response = await session.navigate(direction)
                await handle(
                    response,
                    sessionID: sessionID,
                    generation: generation,
                    callbackRevision: revision
                )

            case let .end(session):
                _ = await session.close()
            }
        }
        workerTask = nil
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
        sessionID: UUID,
        generation: UInt64,
        callbackRevision initialRevision: UInt64
    ) async {
        guard isCurrent(sessionID: sessionID, generation: generation) else {
            return
        }
        switch response {
        case let .success(.result(value)):
            result = value
            isWorking = false
        case .success(.awaitingCallback):
            guard callbackRevision == initialRevision else {
                isWorking = false
                return
            }
            await waitForBackendCallback(
                sessionID: sessionID,
                generation: generation
            )
        case let .failure(failure):
            failureMessage = failure.message
            close(notifyBackend: true, clearFailure: false)
        }
    }

    private func waitForBackendCallback(
        sessionID: UUID,
        generation: UInt64
    ) async {
        await withCheckedContinuation { continuation in
            callbackWaiter = CallbackWaiter(
                sessionID: sessionID,
                generation: generation,
                continuation: continuation
            )
        }
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
        let sessionID: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }
}
